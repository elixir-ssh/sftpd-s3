defmodule Sftpd.BackendTest do
  use ExUnit.Case, async: true

  alias Sftpd.Backend

  describe "file_info/2" do
    test "defaults access to :read_write" do
      mtime = {{2024, 1, 1}, {0, 0, 0}}
      result = Backend.file_info(100, mtime)

      assert {:file_info, 100, :regular, :read_write, ^mtime, ^mtime, ^mtime, 33188, 1, 0, 0, _,
              1, 1} = result
    end
  end

  describe "call/3 with module" do
    test "applies function on module backend" do
      {:ok, mem_state} = Sftpd.Backends.Memory.init([])
      result = Backend.call(Sftpd.Backends.Memory, :list_dir, [~c"/", mem_state])
      assert {:ok, [~c".", ~c".."]} = result
    end
  end

  describe "call/3 with genserver" do
    defmodule EchoServer do
      use GenServer

      def start_link(reply), do: GenServer.start_link(__MODULE__, reply)
      def init(reply), do: {:ok, reply}
      def handle_call({:list_dir, _path, _state}, _from, reply), do: {:reply, reply, reply}
    end

    test "dispatches to genserver process" do
      expected = {:ok, [~c".", ~c"..", ~c"test.txt"]}
      {:ok, pid} = EchoServer.start_link(expected)

      result = Backend.call({:genserver, pid}, :list_dir, [~c"/", nil])
      assert result == expected
    end
  end
end
