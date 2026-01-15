defmodule SftpdTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"testuser",
    password: ~c"testpass"
  ]

  setup do
    port = 10_000 + :rand.uniform(10_000)
    system_dir = Sftpd.SSHKeys.generate_system_dir()

    {:ok, ref} =
      Sftpd.start_server(
        port: port,
        backend: Sftpd.Backends.Memory,
        backend_opts: [],
        users: [{"testuser", "testpass"}],
        system_dir: system_dir
      )

    {:ok, conn} = :ssh.connect(:localhost, port, @client_opts)
    {:ok, channel} = :ssh_sftp.start_channel(conn)

    on_exit(fn ->
      :ssh.close(conn)
      :ssh.stop_daemon(ref)
    end)

    %{channel: channel, port: port}
  end

  describe "directory operations" do
    test "list_dir on root returns . and ..", %{channel: ch} do
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"." in listing
      assert ~c".." in listing
    end

    test "make and list directory", %{channel: ch} do
      assert :ok = :ssh_sftp.make_dir(ch, ~c"/testdir")
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"testdir" in listing
    end

    test "delete directory", %{channel: ch} do
      :ssh_sftp.make_dir(ch, ~c"/delme")
      assert :ok = :ssh_sftp.del_dir(ch, ~c"/delme")
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      refute ~c"delme" in listing
    end
  end

  describe "file operations" do
    test "write and read file", %{channel: ch} do
      content = "Hello, SFTP!"

      # Write file
      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/test.txt", [:write])
      assert :ok = :ssh_sftp.write(ch, handle, content)
      assert :ok = :ssh_sftp.close(ch, handle)

      # Read file - ssh_sftp returns charlist
      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/test.txt", [:read])
      assert {:ok, read_content} = :ssh_sftp.read(ch, handle, byte_size(content))
      assert to_string(read_content) == content
      assert :ok = :ssh_sftp.close(ch, handle)
    end

    test "read_file_info returns file info", %{channel: ch} do
      {:ok, h} = :ssh_sftp.open(ch, ~c"/info.txt", [:write])
      :ssh_sftp.write(ch, h, "12345")
      :ssh_sftp.close(ch, h)

      assert {:ok, {:file_info, 5, :regular, :read_write, _, _, _, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(ch, ~c"/info.txt")
    end

    test "read_file_info on directory", %{channel: ch} do
      :ssh_sftp.make_dir(ch, ~c"/adir")

      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(ch, ~c"/adir")
    end

    test "delete file", %{channel: ch} do
      {:ok, h} = :ssh_sftp.open(ch, ~c"/todelete.txt", [:write])
      :ssh_sftp.write(ch, h, "bye")
      :ssh_sftp.close(ch, h)

      assert :ok = :ssh_sftp.delete(ch, ~c"/todelete.txt")
      assert {:error, :no_such_file} = :ssh_sftp.read_file_info(ch, ~c"/todelete.txt")
    end

    test "rename file", %{channel: ch} do
      {:ok, h} = :ssh_sftp.open(ch, ~c"/oldname.txt", [:write])
      :ssh_sftp.write(ch, h, "content")
      :ssh_sftp.close(ch, h)

      assert :ok = :ssh_sftp.rename(ch, ~c"/oldname.txt", ~c"/newname.txt")
      assert {:error, :no_such_file} = :ssh_sftp.read_file_info(ch, ~c"/oldname.txt")
      assert {:ok, _} = :ssh_sftp.read_file_info(ch, ~c"/newname.txt")
    end
  end

  describe "nested directories" do
    test "create nested structure and list", %{channel: ch} do
      :ssh_sftp.make_dir(ch, ~c"/parent")
      :ssh_sftp.make_dir(ch, ~c"/parent/child")

      {:ok, h} = :ssh_sftp.open(ch, ~c"/parent/child/file.txt", [:write])
      :ssh_sftp.write(ch, h, "nested")
      :ssh_sftp.close(ch, h)

      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/parent")
      assert ~c"child" in listing

      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/parent/child")
      assert ~c"file.txt" in listing
    end
  end
end
