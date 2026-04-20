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

  defmodule RangeEmptyBackend do
    def file_info(_path, _state),
      do: {:ok, Sftpd.Backend.file_info(10, {{2024, 1, 1}, {0, 0, 0}})}

    def read_file_range(_path, _offset, _len, _state), do: {:ok, <<>>}
  end

  defmodule RangeErrorBackend do
    def file_info(_path, _state),
      do: {:ok, Sftpd.Backend.file_info(10, {{2024, 1, 1}, {0, 0, 0}})}

    def read_file_range(_path, _offset, _len, _state), do: {:error, :eio}
  end

  defmodule RangeStatErrorBackend do
    def file_info(_path, _state), do: {:error, :enoent}
    def read_file_range(_path, _offset, _len, _state), do: {:ok, "unused"}
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

  defmodule PartialStreamingBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{test_pid: test_pid}}

    def write_file(_path, content, %{test_pid: test_pid}) do
      send(test_pid, {:partial_written, content})
      :ok
    end
  end

  defmodule ReplayBackend do
    def begin_write(_path, %{agent: agent, test_pid: test_pid}) do
      Agent.get_and_update(agent, fn attempts ->
        next_attempt = attempts + 1

        result =
          case next_attempt do
            1 -> {:error, :fallback_once}
            _ -> {:ok, %{chunks: [], test_pid: test_pid}}
          end

        {result, next_attempt}
      end)
    end

    def write_chunk(handle, offset, chunk, _state) do
      data = IO.iodata_to_binary(chunk)
      send(handle.test_pid, {:replay_chunk, offset, data})
      {:ok, %{handle | chunks: handle.chunks ++ [{offset, data}]}}
    end

    def finish_write(handle, _state) do
      send(handle.test_pid, {:replay_finish, handle.chunks})
      :ok
    end

    def abort_write(handle, _state) do
      send(handle.test_pid, {:replay_abort, handle.chunks})
      :ok
    end
  end

  defmodule StreamingWriteErrorBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{test_pid: test_pid}}
    def write_chunk(_handle, _offset, _chunk, _state), do: {:error, :eio}
    def finish_write(_handle, _state), do: :ok
    def abort_write(_handle, _state), do: {:error, :abort_failed}
  end

  defmodule StreamingFinishErrorBackend do
    def begin_write(_path, %{test_pid: test_pid}), do: {:ok, %{chunks: [], test_pid: test_pid}}

    def write_chunk(handle, offset, chunk, _state) do
      data = IO.iodata_to_binary(chunk)
      {:ok, %{handle | chunks: handle.chunks ++ [{offset, data}]}}
    end

    def finish_write(_handle, _state), do: {:error, :eio}

    def abort_write(handle, _state) do
      send(handle.test_pid, {:finish_error_abort, handle.chunks})
      :ok
    end
  end

  defmodule ReplayWriteErrorBackend do
    def begin_write(_path, %{agent: agent, test_pid: test_pid}) do
      Agent.get_and_update(agent, fn attempts ->
        next_attempt = attempts + 1

        result =
          case next_attempt do
            1 -> {:error, :fallback_once}
            _ -> {:ok, %{test_pid: test_pid}}
          end

        {result, next_attempt}
      end)
    end

    def write_chunk(_handle, _offset, _chunk, _state), do: {:error, :eio}
    def finish_write(_handle, _state), do: :ok
    def abort_write(_handle, _state), do: :ok
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

    test "returns eof when a range backend yields an empty chunk" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/range.txt",
          mode: :read,
          backend: RangeEmptyBackend,
          backend_state: %{}
        })

      assert :eof = GenServer.call(pid, {:read, 3})
    end

    test "returns backend errors from range reads" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/range.txt",
          mode: :read,
          backend: RangeErrorBackend,
          backend_state: %{}
        })

      assert {:error, :eio} = GenServer.call(pid, {:read, 3})
    end

    test "logs and surfaces file_info errors for range backends" do
      log =
        capture_log(fn ->
          {:ok, pid} =
            IODevice.start(%{
              path: ~c"/range.txt",
              mode: :read,
              backend: RangeStatErrorBackend,
              backend_state: %{}
            })

          assert {:error, :enoent} = GenServer.call(pid, {:read, 3})
        end)

      assert log =~ "Failed to stat file"
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

    test "invalid positions return einval" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/test.txt",
          mode: :read,
          backend: MockBackend,
          backend_state: %{content: "0123456789"}
        })

      assert {:error, :einval} = GenServer.call(pid, {:position, {:bogus, 1}})
      assert {:error, :einval} = GenServer.call(pid, {:position, -1})
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

    test "falls back to replay mode when streaming initialization fails" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      log =
        capture_log(fn ->
          {:ok, pid} =
            IODevice.start(%{
              path: ~c"/stream.txt",
              mode: :write,
              backend: ReplayBackend,
              backend_state: %{agent: agent, test_pid: self()}
            })

          assert :ok = GenServer.call(pid, {:write, "hello"})
          assert :ok = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to initialize streaming write"
      assert_receive {:replay_chunk, 0, "hello"}
      assert_receive {:replay_finish, [{0, "hello"}]}
    end

    test "falls back to legacy writes unless all streaming callbacks are present" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/partial.txt",
          mode: :write,
          backend: PartialStreamingBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello"})
      assert :ok = GenServer.call(pid, :close)
      assert_receive {:partial_written, "hello"}, 1000
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

    test "returns write errors and logs cleanup failures for streaming backends" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingWriteErrorBackend,
          backend_state: %{test_pid: self()}
        })

      log =
        capture_log(fn ->
          assert {:error, :eio} = GenServer.call(pid, {:write, "hello"})
          assert {:error, :eio} = GenServer.call(pid, :close)
        end)

      assert log =~ "Streaming write failed"
      assert log =~ "Failed to abort streaming write"
    end

    test "returns errors when finish_write fails" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/stream.txt",
          mode: :write,
          backend: StreamingFinishErrorBackend,
          backend_state: %{test_pid: self()}
        })

      assert :ok = GenServer.call(pid, {:write, "hello"})

      log =
        capture_log(fn ->
          assert {:error, :eio} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to finalize streaming write"
      assert_receive {:finish_error_abort, [{0, "hello"}]}
    end

    test "returns errors when replaying the temp file fails" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      log =
        capture_log(fn ->
          {:ok, pid} =
            IODevice.start(%{
              path: ~c"/stream.txt",
              mode: :write,
              backend: ReplayWriteErrorBackend,
              backend_state: %{agent: agent, test_pid: self()}
            })

          assert :ok = GenServer.call(pid, {:write, "hello"})
          assert {:error, :eio} = GenServer.call(pid, :close)
        end)

      assert log =~ "Failed to replay temp file"
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
