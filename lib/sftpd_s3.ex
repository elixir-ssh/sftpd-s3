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

  ## Examples

      iex> {:ok, _pid} = SftpdS3.start_server(:rand.uniform(65_535))
  """
  @spec start_server(non_neg_integer()) :: {:ok, :ssh.daemon_ref()} | {:error, term()}
  def start_server(port \\ 22) do
    Sftpd.start_server(
      port: port,
      backend: Sftpd.Backends.S3,
      backend_opts: [bucket: Application.get_env(:sftpd, :bucket)],
      users: [{"user", "password"}],
      system_dir: "test/fixtures/ssh_keys"
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
