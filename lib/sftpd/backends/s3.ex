defmodule Sftpd.Backends.S3 do
  @moduledoc """
  S3 storage backend for SFTP server.

  This backend stores files in Amazon S3 or any S3-compatible object storage
  (like MinIO, LocalStack, etc.).

  ## Configuration

      config :sftpd,
        backend: Sftpd.Backends.S3,
        backend_opts: [bucket: "my-bucket"]

  ## Options

  - `:bucket` - (required) The S3 bucket name
  - `:prefix` - (optional) Key prefix for all objects, useful for multi-tenant setups

  ## Dependencies

  This backend requires `ex_aws` and `ex_aws_s3` packages:

      {:ex_aws, "~> 2.0"},
      {:ex_aws_s3, "~> 2.0"},
      {:hackney, "~> 1.9"},
      {:sweet_xml, "~> 0.6"}

  ## ExAws Configuration

  Configure ExAws for your S3 endpoint:

      # For AWS S3
      config :ex_aws,
        access_key_id: "your-key",
        secret_access_key: "your-secret",
        region: "us-east-1"

      # For LocalStack or MinIO
      config :ex_aws, :s3,
        scheme: "http://",
        host: "localhost",
        port: 4566
  """

  @behaviour Sftpd.Backend

  alias Sftpd.Backend

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = Keyword.get(opts, :prefix, "")
    {:ok, %{bucket: bucket, prefix: prefix}}
  end

  @impl true
  def list_dir(path, %{bucket: bucket, prefix: global_prefix}) do
    if root_path?(path) do
      list_root(bucket, global_prefix)
    else
      list_prefix(path, bucket, global_prefix)
    end
  end

  defp root_path?(path), do: path in [~c"/", ~c"/."]

  defp list_root(bucket, global_prefix) do
    case ExAws.request(ExAws.S3.list_objects_v2(bucket, prefix: global_prefix)) do
      {:ok, %{body: %{contents: contents}}} ->
        entries =
          contents
          |> Enum.map(& &1.key)
          |> Enum.map(&trim_prefix(&1, global_prefix))
          |> Enum.map(&(Path.split(&1) |> List.first()))
          |> Enum.reject(&(&1 in ["", ".keep"]))
          |> Enum.uniq()
          |> Enum.map(&to_charlist/1)

        {:ok, [~c".", ~c".." | entries]}

      {:error, _} ->
        {:ok, [~c".", ~c".."]}
    end
  end

  defp trim_prefix(str, ""), do: str
  defp trim_prefix(str, prefix), do: String.trim_leading(str, prefix)

  defp list_prefix(path, bucket, global_prefix) do
    prefix = global_prefix <> Backend.normalize_path(path) <> "/"

    case ExAws.request(ExAws.S3.list_objects_v2(bucket, prefix: prefix)) do
      {:ok, %{body: %{contents: contents}}} ->
        entries =
          contents
          |> Enum.map(& &1.key)
          |> Enum.map(&trim_prefix(&1, prefix))
          |> Enum.map(fn key ->
            case Path.dirname(key) do
              "." -> key
              dirname -> dirname
            end
          end)
          |> Enum.reject(&(&1 in ["", ".keep"]))
          |> Enum.uniq()
          |> Enum.map(&to_charlist/1)

        {:ok, [~c".", ~c".." | entries]}

      {:error, _} ->
        {:ok, [~c".", ~c".."]}
    end
  end

  @impl true
  def file_info(path, %{bucket: bucket, prefix: global_prefix}) do
    # Root path is always a directory
    if root_path?(path) do
      {:ok, Backend.directory_info()}
    else
      key = global_prefix <> Backend.normalize_path(path)

      case ExAws.request(ExAws.S3.head_object(bucket, key)) do
        {:ok, %{headers: headers}} ->
          mtime = extract_mtime(headers)
          size = extract_size(headers)
          {:ok, Backend.file_info(size, mtime, :read_write)}

        {:error, _} ->
          check_directory_exists(key, bucket)
      end
    end
  end

  defp check_directory_exists(key, bucket) do
    prefix = key <> "/"
    list_req = ExAws.S3.list_objects_v2(bucket, prefix: prefix, max_keys: 1)

    case ExAws.request(list_req) do
      {:ok, %{body: %{contents: [_ | _]}}} ->
        {:ok, Backend.directory_info()}

      _ ->
        {:error, :enoent}
    end
  end

  defp extract_mtime(headers) do
    case List.keyfind(headers, "Last-Modified", 0) do
      nil -> NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
      {_, lm} -> parse_http_date(lm)
    end
  end

  defp extract_size(headers) do
    case List.keyfind(headers, "Content-Length", 0) do
      nil -> 0
      {_, length} -> String.to_integer(length)
    end
  end

  @impl true
  def make_dir(path, %{bucket: bucket, prefix: global_prefix}) do
    key = global_prefix <> Backend.normalize_path(path) <> "/.keep"

    case ExAws.request(ExAws.S3.put_object(bucket, key, "")) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :eacces}
    end
  end

  @impl true
  def del_dir(path, %{bucket: bucket, prefix: global_prefix}) do
    key = global_prefix <> Backend.normalize_path(path) <> "/.keep"

    case ExAws.request(ExAws.S3.delete_object(bucket, key)) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> {:error, :enoent}
      {:error, _} -> {:error, :eio}
    end
  end

  @impl true
  def delete(path, %{bucket: bucket, prefix: global_prefix}) do
    key = global_prefix <> Backend.normalize_path(path)

    # S3 delete is idempotent - succeeds even if object doesn't exist
    case ExAws.request(ExAws.S3.delete_object(bucket, key)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def rename(src, dst, %{bucket: bucket, prefix: global_prefix}) do
    src_key = global_prefix <> Backend.normalize_path(src)
    dst_key = global_prefix <> Backend.normalize_path(dst)

    with {:ok, _} <- ExAws.request(ExAws.S3.put_object_copy(bucket, dst_key, bucket, src_key)),
         {:ok, _} <- ExAws.request(ExAws.S3.delete_object(bucket, src_key)) do
      :ok
    else
      {:error, _} -> {:error, :enoent}
    end
  end

  @impl true
  def read_file(path, %{bucket: bucket, prefix: global_prefix}) do
    key = global_prefix <> Backend.normalize_path(path)

    case ExAws.request(ExAws.S3.get_object(bucket, key)) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :enoent}
      {:error, _} -> {:error, :eio}
    end
  end

  @impl true
  def write_file(path, content, %{bucket: bucket, prefix: global_prefix}) do
    key = global_prefix <> Backend.normalize_path(path)

    case ExAws.request(ExAws.S3.put_object(bucket, key, content)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # HTTP date parsing helpers

  defp parse_http_date(date_string) do
    # Try RFC 1123 format: "Sun, 06 Nov 1994 08:49:37 GMT"
    case parse_rfc1123(date_string) do
      {:ok, datetime} -> datetime
      {:error, _} -> NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
    end
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  defp parse_rfc1123(date_string) do
    regex = ~r/\w+, (\d+) (\w+) (\d+) (\d+):(\d+):(\d+) GMT/

    with [_, day, month, year, hour, min, sec] <- Regex.run(regex, date_string),
         {:ok, month_num} <- month_to_number(month) do
      date = {String.to_integer(year), month_num, String.to_integer(day)}
      time = {String.to_integer(hour), String.to_integer(min), String.to_integer(sec)}
      {:ok, {date, time}}
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp month_to_number(month) do
    case Map.fetch(@months, month) do
      {:ok, num} -> {:ok, num}
      :error -> {:error, :invalid_month}
    end
  end
end
