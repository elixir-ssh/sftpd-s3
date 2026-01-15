defmodule Sftpd.Backend do
  @moduledoc """
  Behaviour for SFTP storage backends.

  Implement this behaviour to create custom storage backends for the SFTP server.
  Built-in backends include:

  - `Sftpd.Backends.S3` - Amazon S3 or compatible object storage

  ## Module-Based Backends

  Implement the `Sftpd.Backend` behaviour:

      defmodule MyApp.CustomBackend do
        @behaviour Sftpd.Backend

        @impl true
        def init(opts) do
          {:ok, %{root: opts[:root] || "/"}}
        end

        @impl true
        def list_dir(path, state) do
          {:ok, [~c".", ~c"..", ~c"file.txt"]}
        end

        # ... implement other callbacks
      end

  Then use it:

      Sftpd.start_server(
        backend: MyApp.CustomBackend,
        backend_opts: [root: "/data"],
        ...
      )

  ## Process-Based Backends

  For stateful backends, you can use a GenServer process instead:

      Sftpd.start_server(
        backend: {:genserver, MyApp.BackendServer},
        ...
      )

  The process must handle these calls:

      def handle_call({:list_dir, path}, _from, state)
      def handle_call({:file_info, path}, _from, state)
      def handle_call({:make_dir, path}, _from, state)
      def handle_call({:del_dir, path}, _from, state)
      def handle_call({:delete, path}, _from, state)
      def handle_call({:rename, src, dst}, _from, state)
      def handle_call({:read_file, path}, _from, state)
      def handle_call({:write_file, path, content}, _from, state)

  Each should reply with the same format as the behaviour callbacks.
  """

  @typedoc "Backend state, returned from init/1 and threaded through all calls"
  @type state :: term()

  @typedoc "SFTP path as charlist"
  @type path :: charlist()

  @typedoc "Erlang file_info tuple"
  @type file_info ::
          {:file_info, non_neg_integer(), :regular | :directory, :read | :write | :read_write,
           tuple(), tuple(), tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Initialize the backend with the given options.

  Called once when the SFTP session starts. Returns the initial state
  that will be passed to all subsequent callbacks.
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  List the contents of a directory.

  Returns a list of filenames as charlists. Must include `.` and `..` entries.
  """
  @callback list_dir(path(), state()) :: {:ok, [charlist()]} | {:error, atom()}

  @doc """
  Get file or directory information.

  Returns an Erlang file_info tuple. Use `Sftpd.Backend.file_info/4` or
  `Sftpd.Backend.directory_info/0` helpers to construct these.
  """
  @callback file_info(path(), state()) :: {:ok, file_info()} | {:error, atom()}

  @doc """
  Create a directory.
  """
  @callback make_dir(path(), state()) :: :ok | {:error, atom()}

  @doc """
  Delete an empty directory.
  """
  @callback del_dir(path(), state()) :: :ok | {:error, atom()}

  @doc """
  Delete a file.
  """
  @callback delete(path(), state()) :: :ok | {:error, atom()}

  @doc """
  Rename/move a file or directory.
  """
  @callback rename(src :: path(), dst :: path(), state()) :: :ok | {:error, atom()}

  @doc """
  Read the entire contents of a file.

  For large files, consider implementing streaming in your backend
  and using the `read_file_stream/2` optional callback.
  """
  @callback read_file(path(), state()) :: {:ok, binary()} | {:error, atom()}

  @doc """
  Write content to a file, creating or overwriting it.
  """
  @callback write_file(path(), content :: binary(), state()) :: :ok | {:error, atom()}

  # Helper functions for building file_info tuples

  @doc """
  Build a file_info tuple for a regular file.

  ## Parameters

  - `size` - File size in bytes
  - `mtime` - Modification time as Erlang datetime tuple `{{Y,M,D},{H,M,S}}`
  - `access` - Access mode, one of `:read`, `:write`, `:read_write`
  """
  @spec file_info(non_neg_integer(), :calendar.datetime(), :read | :write | :read_write) ::
          file_info()
  def file_info(size, mtime, access \\ :read_write) do
    {:file_info, size, :regular, access, mtime, mtime, mtime, 33188, 1, 0, 0,
     :rand.uniform(32767), 1, 1}
  end

  @doc """
  Build a file_info tuple for a directory.
  """
  @spec directory_info() :: file_info()
  def directory_info do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.to_erl()

    {:file_info, 4096, :directory, :read, timestamp, timestamp, timestamp, 16877, 2, 0, 0, 0, 1,
     1}
  end

  @doc """
  Normalize an SFTP path to a string without leading slash.

  Useful for backends that use string keys (like S3).
  """
  @spec normalize_path(path() | String.t()) :: String.t()
  def normalize_path(path) do
    path |> to_string() |> String.trim_leading("/")
  end

  # Backend dispatch helpers

  @doc false
  def call({:genserver, server}, operation, args) do
    GenServer.call(server, List.to_tuple([operation | args]))
  end

  def call(module, operation, args) when is_atom(module) do
    apply(module, operation, args)
  end
end
