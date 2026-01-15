defmodule Sftpd.Backends.Memory do
  @moduledoc """
  In-memory storage backend for testing and development.

  This backend stores all files in memory using an Agent. It's useful for:
  - Testing without external dependencies (no S3/LocalStack needed)
  - Development and experimentation
  - As a reference implementation for custom backends

  ## Usage

      {:ok, pid} = Sftpd.start_server(
        port: 2222,
        backend: Sftpd.Backends.Memory,
        backend_opts: [],
        users: [{"user", "pass"}],
        system_dir: "path/to/ssh_keys"
      )

  ## State Structure

  The backend maintains a map of paths to file data:

      %{
        "path/to/file.txt" => %{content: "...", mtime: ~N[...]},
        "path/to/dir/.keep" => %{content: "", mtime: ~N[...]}
      }

  Directories are represented by `.keep` marker files (like S3).
  """

  @behaviour Sftpd.Backend

  alias Sftpd.Backend

  @impl true
  def init(opts) do
    initial_files = Keyword.get(opts, :files, %{})
    {:ok, agent} = Agent.start_link(fn -> initial_files end)
    {:ok, %{agent: agent}}
  end

  @impl true
  def list_dir(path, %{agent: agent}) do
    files = Agent.get(agent, & &1)
    prefix = normalize_prefix(path)

    entries =
      files
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.map(&trim_prefix(&1, prefix))
      |> Enum.map(&(String.split(&1, "/") |> List.first()))
      |> Enum.reject(&(&1 in ["", ".keep"]))
      |> Enum.uniq()
      |> Enum.map(&to_charlist/1)

    {:ok, [~c".", ~c".." | entries]}
  end

  defp trim_prefix(str, ""), do: str
  defp trim_prefix(str, prefix), do: String.trim_leading(str, prefix)

  @impl true
  def file_info(path, %{agent: agent}) do
    if root_path?(path) do
      {:ok, Backend.directory_info()}
    else
      key = Backend.normalize_path(path)
      files = Agent.get(agent, & &1)

      case Map.get(files, key) do
        %{content: content, mtime: mtime} ->
          {:ok, Backend.file_info(byte_size(content), NaiveDateTime.to_erl(mtime), :read_write)}

        nil ->
          # Check if it's a directory
          dir_prefix = key <> "/"

          if Enum.any?(Map.keys(files), &String.starts_with?(&1, dir_prefix)) do
            {:ok, Backend.directory_info()}
          else
            {:error, :enoent}
          end
      end
    end
  end

  @impl true
  def make_dir(path, %{agent: agent}) do
    key = Backend.normalize_path(path) <> "/.keep"

    Agent.update(agent, fn files ->
      Map.put(files, key, %{content: "", mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  @impl true
  def del_dir(path, %{agent: agent}) do
    key = Backend.normalize_path(path) <> "/.keep"

    Agent.update(agent, fn files ->
      Map.delete(files, key)
    end)

    :ok
  end

  @impl true
  def delete(path, %{agent: agent}) do
    key = Backend.normalize_path(path)

    Agent.update(agent, fn files ->
      Map.delete(files, key)
    end)

    :ok
  end

  @impl true
  def rename(src, dst, %{agent: agent}) do
    src_key = Backend.normalize_path(src)
    dst_key = Backend.normalize_path(dst)

    Agent.update(agent, fn files ->
      case Map.pop(files, src_key) do
        {nil, files} -> files
        {data, files} -> Map.put(files, dst_key, data)
      end
    end)

    :ok
  end

  @impl true
  def read_file(path, %{agent: agent}) do
    key = Backend.normalize_path(path)
    files = Agent.get(agent, & &1)

    case Map.get(files, key) do
      %{content: content} -> {:ok, content}
      nil -> {:error, :enoent}
    end
  end

  @impl true
  def write_file(path, content, %{agent: agent}) do
    key = Backend.normalize_path(path)

    Agent.update(agent, fn files ->
      Map.put(files, key, %{content: content, mtime: NaiveDateTime.utc_now()})
    end)

    :ok
  end

  # Helpers

  defp root_path?(path), do: path in [~c"/", ~c"/."]

  defp normalize_prefix(path) when path in [~c"/", ~c"/."], do: ""

  defp normalize_prefix(path) do
    Backend.normalize_path(path) <> "/"
  end
end
