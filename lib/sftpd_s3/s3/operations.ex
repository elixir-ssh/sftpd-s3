defmodule SftpdS3.S3.Operations do
  @moduledoc """
  Wraps ExAws.S3 operations with the output that :ssh_sftpd expects.
  """

  @doc """
  Converts an SFTP path (charlist or string) to an S3 key.
  Removes leading slashes since S3 keys don't use them.
  """
  @spec to_s3_key(charlist() | String.t()) :: String.t()
  def to_s3_key(path) do
    path |> to_string() |> String.trim_leading("/")
  end

  @spec read_stream(String.t() | charlist(), String.t()) :: Enumerable.t()
  def read_stream(key, bucket) do
    ExAws.S3.download_file(bucket, to_s3_key(key), :memory)
    |> ExAws.stream!()
  end

  @spec make_dir(charlist(), String.t()) :: :ok | {:error, :eexists}
  def make_dir(path, bucket) do
    key = to_s3_key(path) <> "/.keep"

    case ExAws.request(ExAws.S3.put_object(bucket, key, "")) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :eexists}
    end
  end

  @spec del_dir(charlist(), String.t()) :: :ok | {:error, :enoent}
  def del_dir(path, bucket) do
    key = to_s3_key(path) <> "/.keep"

    case ExAws.request(ExAws.S3.delete_object(bucket, key)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :enoent}
    end
  end

  @spec list_dir(charlist, String.t()) :: [charlist()]
  def list_dir(path, bucket) when path in [~c"/", ~c"/."] do
    case ExAws.request(ExAws.S3.list_objects_v2(bucket)) do
      {:ok, %{body: %{contents: contents}}} ->
        contents
        |> Enum.map(& &1.key)
        |> Enum.map(&(Path.split(&1) |> List.first()))
        |> Enum.reject(&(&1 == ".keep"))
        |> Enum.uniq()
        |> Enum.map(&to_charlist/1)
        |> Enum.concat([~c".", ~c".."])

      {:error, _} ->
        [~c".", ~c".."]
    end
  end

  def list_dir(path, bucket) do
    prefix = to_s3_key(path) <> "/"

    case ExAws.request(ExAws.S3.list_objects_v2(bucket, prefix: prefix)) do
      {:ok, %{body: %{contents: contents}}} ->
        contents
        |> Enum.map(& &1.key)
        |> Enum.map(&String.trim_leading(&1, prefix))
        |> Enum.map(fn key ->
          case Path.dirname(key) do
            "." -> key
            dirname -> dirname
          end
        end)
        |> Enum.reject(&(&1 in ["", ".keep"]))
        |> Enum.uniq()
        |> Enum.map(&to_charlist/1)
        |> Enum.concat([~c".", ~c".."])

      {:error, _} ->
        [~c".", ~c".."]
    end
  end

  @spec read_link_info(charlist, String.t()) ::
          {:ok, tuple} | {:error, :enoent}

  def read_link_info(path, _bucket) when path in [~c"/", ~c"/.", ~c"/..", ~c"..", ~c"."] do
    {:ok, fake_directory_info()}
  end

  def read_link_info(path, bucket) do
    path_str = to_string(path)

    # Handle paths ending in /. or /.. (e.g., /foldertest/. or /foldertest/..)
    if String.ends_with?(path_str, "/.") or String.ends_with?(path_str, "/..") do
      {:ok, fake_directory_info()}
    else
      read_link_info_from_s3(path, bucket)
    end
  end

  defp read_link_info_from_s3(path, bucket) do
    key = to_s3_key(path)

    case ExAws.request(ExAws.S3.head_object(bucket, key)) do
      {:ok, %{headers: headers}} ->
        mtime = extract_mtime(headers)
        size = extract_size(headers)
        {:ok, file_info(size, :regular, :read_write, mtime)}

      {:error, _} ->
        # Check if it might be a directory (has objects with this prefix)
        check_directory_exists(key, bucket)
    end
  end

  defp check_directory_exists(key, bucket) do
    prefix = key <> "/"
    list_req = ExAws.S3.list_objects_v2(bucket, prefix: prefix, max_keys: 1)

    case ExAws.request(list_req) do
      {:ok, %{body: %{contents: [_ | _]}}} ->
        {:ok, fake_directory_info()}

      _ ->
        {:error, :enoent}
    end
  end

  defp extract_mtime(headers) do
    case List.keyfind(headers, "Last-Modified", 0) do
      nil -> NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
      {_, lm} -> get_erl_time_from_rfc1123(lm)
    end
  end

  defp extract_size(headers) do
    case List.keyfind(headers, "Content-Length", 0) do
      nil -> 0
      {_, length} -> String.to_integer(length)
    end
  end

  defp file_info(size, type, access, mtime) do
    {:file_info, size, type, access, mtime, mtime, mtime, 33261, 1, 0, 0, :rand.uniform(32767), 1,
     1}
  end

  @spec delete(charlist(), String.t()) :: :ok | {:error, :enoent}
  def delete(path, bucket) do
    key = to_s3_key(path)

    case ExAws.request(ExAws.S3.delete_object(bucket, key)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :enoent}
    end
  end

  @spec rename(charlist(), charlist(), String.t()) :: :ok | {:error, atom()}
  def rename(src, dst, bucket) do
    src_key = to_s3_key(src)
    dst_key = to_s3_key(dst)

    with {:ok, _} <- ExAws.request(ExAws.S3.put_object_copy(bucket, dst_key, bucket, src_key)),
         {:ok, _} <- ExAws.request(ExAws.S3.delete_object(bucket, src_key)) do
      :ok
    else
      {:error, _} -> {:error, :enoent}
    end
  end

  @spec fake_directory_info :: tuple
  def fake_directory_info do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()

    {:file_info, 640, :directory, :read, timestamp, timestamp, timestamp, 16877, 20, 16_777_230,
     0, 2, 1, 1}
  end

  defp get_erl_time_from_rfc1123(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} ->
        datetime |> DateTime.to_naive() |> NaiveDateTime.to_erl()

      {:error, _} ->
        case parse_rfc1123(date_string) do
          {:ok, datetime} ->
            datetime |> NaiveDateTime.to_erl()

          {:error, _} ->
            NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
        end
    end
  end

  defp parse_rfc1123(date_string) do
    case NaiveDateTime.from_iso8601(date_string) do
      {:ok, naive_datetime} ->
        {:ok, naive_datetime}

      {:error, _} ->
        case parse_rfc1123_fallback(date_string) do
          {:ok, naive_datetime} -> {:ok, naive_datetime}
          {:error, _} -> {:error, :invalid_format}
        end
    end
  end

  defp parse_rfc1123_fallback(date_string) do
    with {:ok, [_day_name, day, month, year, time, "GMT"]} <-
           Regex.run(~r/(\w+), (\d+) (\w+) (\d+) (\d+:\d+:\d+) GMT/, date_string),
         {:ok, naive_datetime} <- parse_naive_datetime(day, month, year, time) do
      {:ok, naive_datetime}
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_naive_datetime(day, month, year, time) do
    month_number =
      %{
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
      }[month]

    case NaiveDateTime.from_erl(
           {{String.to_integer(year), month_number, String.to_integer(day)}, parse_time(time)}
         ) do
      {:ok, naive_datetime} -> {:ok, naive_datetime}
      {:error, _} -> {:error, :invalid_format}
    end
  end

  defp parse_time(time) do
    [hour, minute, second] = String.split(time, ":") |> Enum.map(&String.to_integer/1)
    {hour, minute, second}
  end
end
