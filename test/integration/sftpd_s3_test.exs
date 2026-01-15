defmodule SftpdS3Test do
  use ExUnit.Case, async: true

  doctest SftpdS3

  @port 1337

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"user",
    password: ~c"password"
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

    %{bucket: bucket, path: "foldertest/9/assets.csv", local_path: local_path}
  end

  describe "SFTP Server" do
    test "happy path for read", %{path: path, local_path: local_path} do
      assert {:ok, _ref} = start_ssh_server()
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/")

      assert Enum.sort(listing) == Enum.sort([~c".", ~c"..", ~c"foldertest"])

      assert {:ok,
              {:file_info, _size, :directory, :read_write, time, time, time, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(channel_ref, ~c"/foldertest")

      assert {:ok,
              {:file_info, size, :regular, :read_write, time, time, time, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(channel_ref, path |> to_charlist()) |> dbg()

      assert {:ok, "0"} = :ssh_sftp.open(channel_ref, path |> to_charlist(), [:read])

      assert {:ok, data} = :ssh_sftp.read(channel_ref, "0", size)

      assert File.read!(local_path) == data |> Enum.into(<<>>, fn byte -> <<byte::8>> end)

      assert :ok = :ssh_sftp.close(channel_ref, "0")
    end

    test "happy path for make and delete directory", %{path: _path} do
      assert {:ok, _ref} = start_ssh_server()
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/")

      assert Enum.sort(listing) == Enum.sort([~c".", ~c"..", ~c"foldertest"])

      assert {:ok, "0"} = :ssh_sftp.opendir(channel_ref, ~c"/foldertest")

      assert :ok = :ssh_sftp.make_dir(channel_ref, ~c"/foldertest/15")

      assert {:ok, [~c"..", ~c".", ~c"9", ~c"15", ~c"11", ~c"10"]} =
               :ssh_sftp.list_dir(channel_ref, ~c"/foldertest")

      assert :ok = :ssh_sftp.del_dir(channel_ref, ~c"/foldertest/15")
    end

    test "happy path for upload without cd", %{path: _path} do
      assert {:ok, _ref} = start_ssh_server()
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/")

      assert Enum.sort(listing) == Enum.sort([~c".", ~c"..", ~c"foldertest"])

      # Create the directory first
      assert :ok = :ssh_sftp.make_dir(channel_ref, ~c"/foldertest/15")

      # Now open a file for writing
      assert {:ok, handle} = :ssh_sftp.open(channel_ref, ~c"/foldertest/15/assets.csv", [:write])

      # Write some data
      assert :ok = :ssh_sftp.write(channel_ref, handle, "hello world")

      # Close the file
      assert :ok = :ssh_sftp.close(channel_ref, handle)

      # Verify the file was created and can be read back
      assert {:ok, handle2} = :ssh_sftp.open(channel_ref, ~c"/foldertest/15/assets.csv", [:read])
      assert {:ok, ~c"hello world"} = :ssh_sftp.read(channel_ref, handle2, 11)
      assert :ok = :ssh_sftp.close(channel_ref, handle2)
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
      {:ok, ref} ->
        on_exit(fn ->
          :ssh.stop_daemon(ref)
        end)

        {:ok, ref}

      {:error, :eaddrinuse} ->
        :ok
    end
  end
end
