defmodule Sftpd.IODeviceTest do
  use ExUnit.Case, async: true

  alias Sftpd.IODevice

  # Mock backend for testing
  defmodule MockBackend do
    def read_file(_path, %{content: content}), do: {:ok, content}
    def read_file(_path, %{error: reason}), do: {:error, reason}

    def write_file(_path, content, state) do
      send(state.test_pid, {:written, content})
      :ok
    end
  end

  describe "read mode" do
    test "reads file content on init" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello world"}
        })

      assert {:ok, "hello"} = GenServer.call(pid, {:read, 5})
      assert {:ok, " worl"} = GenServer.call(pid, {:read, 5})
      assert {:ok, "d"} = GenServer.call(pid, {:read, 5})
      assert :eof = GenServer.call(pid, {:read, 5})
    end

    test "handles read error gracefully" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/missing.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{error: :enoent}
        })

      assert {:error, :enoent} = GenServer.call(pid, {:read, 10})
    end

    test "position bof sets absolute position" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      assert {:ok, 5} = GenServer.call(pid, {:position, {:bof, 5}})
      assert {:ok, "56789"} = GenServer.call(pid, {:read, 10})
    end

    test "position cur sets relative position" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      # Read 3 bytes to move position to 3
      assert {:ok, "012"} = GenServer.call(pid, {:read, 3})

      # Move 2 bytes forward from current position
      assert {:ok, 5} = GenServer.call(pid, {:position, {:cur, 2}})
      assert {:ok, "56789"} = GenServer.call(pid, {:read, 10})
    end

    test "position with integer sets absolute position" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      assert {:ok, 7} = GenServer.call(pid, {:position, 7})
    end

    test "returns eof when position is at or past end" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "abc"}
        })

      assert {:ok, 10} = GenServer.call(pid, {:position, {:bof, 10}})
      assert :eof = GenServer.call(pid, {:read, 1})
    end
  end

  describe "write mode" do
    test "buffers writes and uploads on close" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello "})
      assert :ok = GenServer.call(pid, {:write, "world"})

      # Trigger close via file_request message
      send(pid, {:file_request, self(), make_ref(), :close})

      assert_receive {:written, "hello world"}, 1000
    end

    test "uploads buffer on terminate" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "content"})

      # Stop the process
      GenServer.stop(pid)

      assert_receive {:written, "content"}, 1000
    end

    test "position bof always returns 0 in write mode" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert {:ok, 0} = GenServer.call(pid, {:position, {:bof, 100}})
    end

    test "handles iodata in writes" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, [?a, "bc", [?d, ?e]]})

      GenServer.stop(pid)

      assert_receive {:written, "abcde"}, 1000
    end
  end
end
