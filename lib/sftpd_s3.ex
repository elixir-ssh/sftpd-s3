defmodule SftpdS3 do
  @moduledoc """
  Documentation for `SftpdS3`.
  """

  @doc """
  Start a new test SFTP server.

  This should be replaced with a child_spec.

  ## Examples

      iex> {:ok, _pid} = SftpdS3.start_server(:rand.uniform(65_535))
  """

  def start_server(port \\ 22)

  @spec start_server(non_neg_integer) :: any
  def start_server(port) do
    :ssh.daemon(port, [
      {:max_sessions, 1},
      {:user_passwords, [{~c"user", ~c"password"}]},
      {:system_dir, ~c"test/fixtures/ssh_keys"},
      {:subsystems,
       [
         :ssh_sftpd.subsystem_spec(
           cwd: ~c"/",
           root: ~c"/",
           file_handler: {
             SftpdS3.S3.FileHandler,
             %{bucket: Application.get_env(:sftpd_s3, :bucket)}
           }
         )
       ]}
    ])
  end

  @doc """
    Stop a SSH daemon.

    This stops the whole daemon.
    You probably want to roll your own thing that removes the sftp handler instead.

    ## Examples

        iex> {:ok, pid} = SftpdS3.start_server(:rand.uniform(65_535))
        iex> SftpdS3.stop_server(pid)
  """
  def stop_server(pid) do
    :ssh.stop_daemon(pid)
  end
end
