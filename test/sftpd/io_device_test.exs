defmodule Sftpd.IODeviceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sftpd.IODevice

  defmodule MockBackend do
    def read_file(_path, %{content: content}), do: {:ok, content}
    def read_file(_path, %{error: reason}), do: {:error, reason}

    def write_file(_path, _content, %{write_error: reason}), do: {:error, reason}

    def write_file(_path, content, state) do
      send(state.test_pid, {:written, content})
      :ok
    end
  end

  defmodule RangeBackend do
    def file_info(_path, %{content: content}) do
      {:ok, Sftpd.Backend.file_info(byte_size(content), {{2024, 1, 1}, {0, 0, 0}})}
    end

    def read_file_range(_path, offset, len, %{content: content}) do
      size = byte_size(content)

      if offset >= size do
        :eof
      else
        bytes_to_read = min(len, size - offset)
        {:ok, binary_part(content, offset, bytes_to_read)}
      end
    end
  end

  defmodule StreamingBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{chunks: [], test_pid: test_pid}}

    def write_chunk(handle, offset, chunk, _state) do
      data = IO.iodata_to_binary(chunk)
      send(handle.test_pid, {:stream_chunk, offset, data})
      {:ok, %{handle | chunks: handle.chunks ++ [{offset, data}]}}
    end

    def finish_write(handle, _state) do
      send(handle.test_pid, {:stream_finish, handle.chunks})
      :ok
    end

    def abort_write(handle, _state) do
      send(handle.test_pid, {:stream_abort, handle.chunks})
      :ok
    end
  end

  describe "read mode" do
    test "reads file content on init for legacy backends" do
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

    test "uses read_file_range when the backend supports it" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/range.txt",
          mode: :read,
          backend: RangeBackend,
          backend_state: %{content: "abcdefghij"}
        })

      assert {:ok, "abc"} = GenServer.call(pid, {:read, 3})
      assert {:ok, "defg"} = GenServer.call(pid, {:read, 4})
      assert {:ok, 8} = GenServer.call(pid, {:position, {:eof, -2}})
      assert {:ok, "ij"} = GenServer.call(pid, {:read, 4})
      assert :eof = GenServer.call(pid, {:read, 1})
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

      assert {:ok, "012"} = GenServer.call(pid, {:read, 3})
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
      assert {:ok, "789"} = GenServer.call(pid, {:read, 10})
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

    test "close message stops read-mode process" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello"}
        })

      ref = Process.monitor(pid)
      send(pid, {:file_request, self(), make_ref(), :close})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "terminate is clean for read mode" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello"}
        })

      assert :ok = GenServer.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "write mode" do
    test "persists writes through the legacy backend on close" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello "})
      assert :ok = GenServer.call(pid, {:write, "world"})
      assert :ok = GenServer.call(pid, :close)

      assert_receive {:written, "hello world"}, 1000
      refute_receive {:written, _}, 200
    end

    test "does not upload buffered content on terminate" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "content"})
      GenServer.stop(pid)

      refute_receive {:written, _}, 200
    end

    test "logs and returns an error when legacy finalization fails" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{write_error: :eacces}
        })

      assert :ok = GenServer.call(pid, {:write, "content"})

      log =
        capture_log(fn ->
          assert {:error, :eacces} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to finalize legacy write"
    end

    test "position bof updates the write cursor" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert {:ok, 100} = GenServer.call(pid, {:position, {:bof, 100}})
    end

    test "position eof returns einval in write mode" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/output.txt",
          mode: :write,
          backend: MockBackend,
          backend_state: %{test_pid: self()}
        })

      assert {:error, :einval} = GenServer.call(pid, {:position, {:eof, 0}})
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
      assert :ok = GenServer.call(pid, :close)

      assert_receive {:written, "abcde"}, 1000
    end

    test "finalizes active streaming writes on close" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello"})
      assert_receive {:stream_chunk, 0, "hello"}
      assert :ok = GenServer.call(pid, :close)
      assert_receive {:stream_finish, [{0, "hello"}]}
    end

    test "non-sequential writes downgrade to temp-file replay mode" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "abc"})
      assert_receive {:stream_chunk, 0, "abc"}

      assert {:ok, 1} = GenServer.call(pid, {:position, {:bof, 1}})
      assert :ok = GenServer.call(pid, {:write, "Z"})
      assert_receive {:stream_abort, [{0, "abc"}]}

      assert :ok = GenServer.call(pid, :close)
      assert_receive {:stream_chunk, 0, "aZc"}
      assert_receive {:stream_finish, [{0, "aZc"}]}
    end
  end

  describe "handle_info catch-all" do
    test "ignores unknown messages and stays alive" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "hello"}
        })

      send(pid, :unknown_message)
      send(pid, {:some, :other, :message})

      assert {:ok, "hello"} = GenServer.call(pid, {:read, 5})
    end
  end
end
