defmodule SftpdS3 do
  @moduledoc """
  Legacy module for backwards compatibility.

  This module is deprecated. Please use `Sftpd` instead.

  ## Migration

  Replace:

      SftpdS3.start_server(port)

  With:

      Sftpd.start_server(
        port: port,
        backend: Sftpd.Backends.S3,
        backend_opts: [bucket: "your-bucket"],
        users: [{"user", "password"}],
        system_dir: "path/to/ssh_keys"
      )
  """

  @doc """
  Start a test SFTP server with default settings.

  Deprecated: Use `Sftpd.start_server/1` instead.

  ## Options

  - `:system_dir` - Directory containing SSH host keys (required)
  """
  @spec start_server(non_neg_integer(), keyword()) :: {:ok, :ssh.daemon_ref()} | {:error, term()}
  def start_server(port \\ 22, opts \\ []) do
    system_dir = Keyword.fetch!(opts, :system_dir)

    Sftpd.start_server(
      port: port,
      backend: Sftpd.Backends.S3,
      backend_opts: [bucket: Application.get_env(:sftpd, :bucket)],
      users: [{"user", "password"}],
      system_dir: system_dir
    )
  end

  @doc """
  Stop an SFTP server.

  Deprecated: Use `Sftpd.stop_server/1` instead.
  """
  @spec stop_server(:ssh.daemon_ref()) :: :ok | {:error, term()}
  def stop_server(ref) do
    Sftpd.stop_server(ref)
  end
end
