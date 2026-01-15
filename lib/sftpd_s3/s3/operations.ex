defmodule SftpdS3.S3.Operations do
  @moduledoc """
  Wraps ExAws.S3 operations with the output that :ssh_sftpd expects.
  """

  # TODO: all of this code is very poorly written and should be refactored before this PR is merged.

  @spec read_stream(String.t() | charlist(), String.t()) :: any
  def read_stream(key, bucket) do
    ExAws.S3.download_file(bucket, key, :memory)
    |> ExAws.stream!()
  end

  @spec make_dir(charlist, String.t()) :: :ok | {:error, :eexists}
  def make_dir(path, bucket) do
    key = (path |> to_string()) <> "/.keep"
    req = ExAws.S3.put_object(bucket, key, "")

    case ExAws.request(req) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, :eexists}
    end
  end

  @spec del_dir(charlist, String.t()) :: :ok | {:error, :enoent}
  def del_dir(path, bucket) do
    key = (path |> to_string()) <> "/.keep"
    req = ExAws.S3.delete_object(bucket, key)

    case ExAws.request(req) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, :enoent}
    end
  end

  @spec list_dir(charlist, String.t() | nil) :: any
  def list_dir(path, bucket) when path in [~c"/", ~c"/."] do
    req = ExAws.S3.list_objects_v2(bucket)

    case ExAws.request(req) do
      {:ok, %{body: %{contents: contents}}} ->
        contents
        |> get_in([Access.all(), :key])
        |> Enum.map(fn key ->
          Path.split(key) |> List.first() |> to_charlist()
        end)
        |> Enum.uniq()
        |> Enum.concat([~c".", ~c".."])

      {:error, err} ->
        err
    end
  end

  def list_dir(path, bucket) do
    path = path |> to_string() |> String.trim("/")
    path = "#{path}/"

    req = ExAws.S3.list_objects_v2(bucket, prefix: path)

    case ExAws.request(req) do
      {:ok, %{body: %{contents: contents}}} ->
        # get_in/2 is slow but easy to write.
        contents
        |> get_in([Access.all(), :key])
        |> Enum.map(fn key ->
          key_without_prefix = key |> String.trim_leading(path)

          case Path.dirname(key_without_prefix) do
            "." -> key_without_prefix
            dirname -> dirname
          end
          |> to_charlist()
        end)
        |> Enum.uniq()
        |> Enum.concat([~c".", ~c".."])

      {:error, err} ->
        err
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
    key = path |> to_string()
    head_object = ExAws.S3.head_object(bucket, key)

    case ExAws.request(head_object) do
      {:ok, %{headers: headers}} ->
        mtime =
          headers
          |> List.keyfind("Last-Modified", 0)
          |> then(fn
            nil -> NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()
            {_, lm} -> get_erl_time_from_rfc1123(lm)
          end)

        size =
          headers
          |> List.keyfind("Content-Length", 0)
          |> then(fn
            nil -> 0
            {_, length} -> String.to_integer(length)
          end)

        {:ok,
         {
           :file_info,
           # size
           size,
           # type,
           :regular,
           # access
           :read_write,
           # atime
           mtime,
           # mtime
           mtime,
           # ctime
           mtime,
           # unix_permission_mode
           33261,
           # hard_link_count
           1,
           # major_device
           0,
           # minor_device
           0,
           # inode
           Enum.random(0..32767),
           # uid
           1,
           # gid
           1
         }}

      {:error, _err} ->
        # Check if it might be a directory (has objects with this prefix)
        prefix = (key |> String.trim_leading("/")) <> "/"
        list_req = ExAws.S3.list_objects_v2(bucket, prefix: prefix, max_keys: 1)

        case ExAws.request(list_req) do
          {:ok, %{body: %{contents: [_ | _]}}} ->
            # Has contents with this prefix, so it's a directory
            {:ok, fake_directory_info()}

          _ ->
            # Not a file and not a directory with contents
            {:error, :enoent}
        end
    end
  end

  @spec delete(charlist, String.t()) :: :ok | {:error, :enoent}
  def delete(path, bucket) do
    key = path |> to_string()
    req = ExAws.S3.delete_object(bucket, key)

    case ExAws.request(req) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, :enoent}
    end
  end

  @spec rename(charlist, charlist, String.t()) :: :ok | {:error, atom}
  def rename(src, dst, bucket) do
    src_key = src |> to_string()
    dst_key = dst |> to_string()

    # Copy the object to the new location
    copy_req = ExAws.S3.put_object_copy(bucket, dst_key, bucket, src_key)

    case ExAws.request(copy_req) do
      {:ok, _} ->
        # Delete the old object
        delete_req = ExAws.S3.delete_object(bucket, src_key)

        case ExAws.request(delete_req) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :enoent}
        end

      {:error, _} ->
        {:error, :enoent}
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
