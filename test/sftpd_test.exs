defmodule SftpdTest do
  use ExUnit.Case, async: false

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"testuser",
    password: ~c"testpass"
  ]

  # GenServer backend that wraps Memory for testing {:genserver, pid} dispatch
  defmodule GenServerBackend do
    use GenServer
    alias Sftpd.Backends.Memory

    def start_link, do: GenServer.start_link(__MODULE__, [])

    def init(_), do: Memory.init([])

    def handle_call({:list_dir, path}, _from, mem_state),
      do: {:reply, Memory.list_dir(path, mem_state), mem_state}

    def handle_call({:file_info, path}, _from, mem_state),
      do: {:reply, Memory.file_info(path, mem_state), mem_state}

    def handle_call({:make_dir, path}, _from, mem_state) do
      :ok = Memory.make_dir(path, mem_state)
      {:reply, :ok, mem_state}
    end

    def handle_call({:del_dir, path}, _from, mem_state),
      do: {:reply, Memory.del_dir(path, mem_state), mem_state}

    def handle_call({:delete, path}, _from, mem_state),
      do: {:reply, Memory.delete(path, mem_state), mem_state}

    def handle_call({:rename, src, dst}, _from, mem_state),
      do: {:reply, Memory.rename(src, dst, mem_state), mem_state}

    def handle_call({:read_file, path}, _from, mem_state),
      do: {:reply, Memory.read_file(path, mem_state), mem_state}

    def handle_call({:write_file, path, content}, _from, mem_state) do
      :ok = Memory.write_file(path, content, mem_state)
      {:reply, :ok, mem_state}
    end
  end

  setup do
    port = 10_000 + :rand.uniform(10_000)
    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

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

  describe "init_backend error handling" do
    defmodule FailingBackend do
      def init(_opts), do: {:error, :init_failed}
    end

    test "start_server propagates backend init error" do
      assert {:error, :init_failed} =
               Sftpd.start_server(
                 backend: FailingBackend,
                 system_dir: "/tmp",
                 users: []
               )
    end
  end

  describe "genserver backend" do
    setup do
      port = 10_000 + :rand.uniform(10_000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      {:ok, server_pid} = GenServerBackend.start_link()

      {:ok, ref} =
        Sftpd.start_server(
          port: port,
          backend: {:genserver, server_pid},
          users: [{"testuser", "testpass"}],
          system_dir: system_dir
        )

      {:ok, conn} = :ssh.connect(:localhost, port, @client_opts)
      {:ok, channel} = :ssh_sftp.start_channel(conn)

      on_exit(fn ->
        :ssh.close(conn)
        :ssh.stop_daemon(ref)
      end)

      %{channel: channel}
    end

    test "list_dir on root works", %{channel: ch} do
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"." in listing
      assert ~c".." in listing
    end

    test "make_dir and list_dir work", %{channel: ch} do
      assert :ok = :ssh_sftp.make_dir(ch, ~c"/gsdir")
      assert {:ok, listing} = :ssh_sftp.list_dir(ch, ~c"/")
      assert ~c"gsdir" in listing
    end

    test "write and read file works", %{channel: ch} do
      content = "genserver file content"

      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/gs_file.txt", [:write])
      assert :ok = :ssh_sftp.write(ch, handle, content)
      assert :ok = :ssh_sftp.close(ch, handle)

      assert {:ok, handle} = :ssh_sftp.open(ch, ~c"/gs_file.txt", [:read])
      assert {:ok, read_content} = :ssh_sftp.read(ch, handle, byte_size(content))
      assert to_string(read_content) == content
      assert :ok = :ssh_sftp.close(ch, handle)
    end
  end
end
