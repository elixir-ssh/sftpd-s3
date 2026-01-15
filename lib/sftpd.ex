defmodule Sftpd do
  @moduledoc """
  A pluggable SFTP server with support for multiple storage backends.

  Sftpd wraps Erlang's `:ssh_sftpd` module and provides a clean API for
  starting SFTP servers with configurable storage backends.

  ## Quick Start

      # Start an SFTP server with S3 backend
      {:ok, pid} = Sftpd.start_server(
        port: 2222,
        backend: Sftpd.Backends.S3,
        backend_opts: [bucket: "my-bucket"],
        users: [{"user", "password"}]
      )

  ## Backends

  Sftpd supports pluggable backends. Built-in backends:

  - `Sftpd.Backends.S3` - Amazon S3 or S3-compatible storage

  To create a custom backend, implement the `Sftpd.Backend` behaviour.

  ## Options

  - `:port` - Port to listen on (default: 22)
  - `:backend` - Backend module or `{:genserver, pid_or_name}` (required)
  - `:backend_opts` - Options passed to `backend.init/1` for module backends (default: [])
  - `:users` - List of `{username, password}` tuples for authentication
  - `:system_dir` - Directory containing SSH host keys (required)
  - `:max_sessions` - Maximum concurrent sessions (default: 10)

  ## Process-Based Backends

  Instead of a module, you can use a running GenServer:

      {:ok, pid} = MyBackendServer.start_link()
      Sftpd.start_server(backend: {:genserver, pid}, ...)

  See `Sftpd.Backend` for the messages your GenServer must handle.

  ## SSH Host Keys

  You need SSH host keys for the server. Generate them with:

      ssh-keygen -t rsa -f ssh_host_rsa_key -N ""
      ssh-keygen -t ecdsa -f ssh_host_ecdsa_key -N ""

  Then set `:system_dir` to the directory containing these keys.
  """

  @default_port 22
  @default_max_sessions 10

  @type server_ref :: :ssh.daemon_ref()

  @doc """
  Start an SFTP server.

  ## Examples

      # Start with S3 backend
      {:ok, pid} = Sftpd.start_server(
        port: 2222,
        backend: Sftpd.Backends.S3,
        backend_opts: [bucket: "my-bucket"],
        users: [{"admin", "secret"}],
        system_dir: "/etc/ssh"
      )

  ## Options

  See module documentation for full list of options.
  """
  @spec start_server(keyword()) :: {:ok, server_ref()} | {:error, term()}
  def start_server(opts) do
    port = Keyword.get(opts, :port, @default_port)
    backend = Keyword.fetch!(opts, :backend)
    backend_opts = Keyword.get(opts, :backend_opts, [])
    users = Keyword.get(opts, :users, [])
    system_dir = Keyword.fetch!(opts, :system_dir)
    max_sessions = Keyword.get(opts, :max_sessions, @default_max_sessions)

    {backend, backend_state} = init_backend(backend, backend_opts)

    user_passwords =
      Enum.map(users, fn {user, pass} ->
        {to_charlist(user), to_charlist(pass)}
      end)

    :ssh.daemon(port, [
      {:max_sessions, max_sessions},
      {:user_passwords, user_passwords},
      {:system_dir, to_charlist(system_dir)},
      {:subsystems,
       [
         :ssh_sftpd.subsystem_spec(
           cwd: ~c"/",
           root: ~c"/",
           file_handler: {
             Sftpd.FileHandler,
             %{backend: backend, backend_state: backend_state}
           }
         )
       ]}
    ])
  end

  defp init_backend({:genserver, server}, _opts) do
    # Process-based backend - no init needed, process manages own state
    {{:genserver, server}, nil}
  end

  defp init_backend(module, opts) when is_atom(module) do
    # Module-based backend - call init/1
    {:ok, state} = module.init(opts)
    {module, state}
  end

  @doc """
  Stop an SFTP server.

  ## Examples

      {:ok, pid} = Sftpd.start_server(opts)
      :ok = Sftpd.stop_server(pid)
  """
  @spec stop_server(server_ref()) :: :ok | {:error, term()}
  def stop_server(ref) do
    :ssh.stop_daemon(ref)
  end
end
