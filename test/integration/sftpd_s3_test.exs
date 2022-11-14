defmodule SftpdS3Test do
  use ExUnit.Case, async: true

  doctest SftpdS3

  @port 31337

  @client_opts [
    silently_accept_hosts: true,
    user: 'user',
    password: 'password'
  ]

  setup_all do
    local_path =
      Path.join([
        File.cwd!(),
        "test/fixtures/1mb.txt"
      ])

    file = ExAws.S3.Upload.stream_file(local_path)
    bucket = Application.get_env(:sftpd_s3, :bucket)

    ExAws.S3.put_bucket(bucket, "us-west-2") |> ExAws.request()

    ExAws.S3.upload(file, bucket, "foldertest/9/assets.csv") |> ExAws.request!()
    ExAws.S3.upload(file, bucket, "foldertest/10/assets.csv") |> ExAws.request!()
    ExAws.S3.upload(file, bucket, "foldertest/11/assets.csv") |> ExAws.request!()

    ExAws.S3.upload(file, bucket, "foldertest/11/assets2.csv")
    |> ExAws.request!()

    %{bucket: bucket, path: "foldertest/9/assets.csv" }
  end

  describe "SFTP Server" do
    test "happy path for read", %{path: path} do
      assert {:ok, _ref} = start_ssh_server()
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, '/')

      assert Enum.sort(listing) == Enum.sort(['.', '..', 'foldertest'])

      assert {:ok,
              {:file_info, _size, :directory, :read_write, time, time, time, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(channel_ref, '/foldertest')

      assert {:ok,
              {:file_info, size, :regular, :read_write, time, time, time, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(channel_ref, path |> to_charlist()) |> dbg()

      assert {:ok, "0"} = :ssh_sftp.open(channel_ref, path |> to_charlist(), [:read])

      assert {:ok, data} = :ssh_sftp.read(channel_ref, "0", size)

      # TODO: there is an encoding and a crlf issue here
      expected =
        "ï»¿V,2.0.4\r\nH,Assets,2020-10-02T04:11:54-05:00\r\nC,Unique Borrower Identifier,Asset Type,Amount\r\nT,0"

      assert expected == data |> to_string()

      assert :ok = :ssh_sftp.close(channel_ref, "0")

    end

    test "happy path for make and delete directory", %{path: _path} do
      assert {:ok, _ref} = start_ssh_server()
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, '/')

      assert Enum.sort(listing) == Enum.sort(['foldertest'])

      assert {:ok, "0"} = :ssh_sftp.opendir(channel_ref, '/foldertest')

      assert :ok = :ssh_sftp.make_dir(channel_ref, '/foldertest/15')

      assert {:ok, ['..', '.', '9', '15', '11', '10']} =
               :ssh_sftp.list_dir(channel_ref, '/foldertest')

      assert :ok = :ssh_sftp.del_dir(channel_ref, '/foldertest/15')
    end

    test "happy path for upload without cd", %{path: _path} do
      assert {:ok, _ref} = start_ssh_server()
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, '/')

      assert Enum.sort(listing) == Enum.sort(['foldertest'])

      assert {:ok, "0"} = :ssh_sftp.open(channel_ref, '/foldertest/15/assets.csv', [:write])

      assert false = :ssh_sftp.write(channel_ref, "0", "hello")
    end
  end

  defp start_ssh_client do
    # connect client
    assert {:ok, client_connection_ref} = :ssh.connect(:localhost, @port, @client_opts)

    assert {:ok, channel_ref} = :ssh_sftp.start_channel(client_connection_ref)

    on_exit(fn -> :ssh.close(client_connection_ref) end)

    %{client_connection_ref: client_connection_ref, channel_ref: channel_ref}
  end

  defp start_ssh_server do
    case SftpdS3.start_server(@port) do
      {:ok, ref} ->     on_exit(fn ->
        :ssh.stop_daemon(ref)
      end)
      {:ok, ref}
      {:error, :eaddrinuse} -> :ok
    end
  end
end
