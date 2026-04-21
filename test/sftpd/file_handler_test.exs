defmodule Sftpd.FileHandlerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Sftpd.FileHandler

  @state %{backend: nil, backend_state: nil}

  defmodule MockBackend do
    def read_file(_path, _state), do: {:ok, "content"}
  end

  defmodule SlowCloseDevice do
    use GenServer

    def start, do: GenServer.start(__MODULE__, [])

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_call(:close, _from, state) do
      Process.sleep(50)
      {:stop, :normal, :ok, state}
    end
  end

  defmodule HangingCloseDevice do
    use GenServer

    def start, do: GenServer.start(__MODULE__, [])

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_call(:close, _from, state) do
      Process.sleep(:infinity)
      {:reply, :ok, state}
    end
  end

  defmodule ControlledCloseDevice do
    use GenServer

    def start(test_pid, release_delay \\ nil),
      do: GenServer.start(__MODULE__, {test_pid, release_delay})

    @impl true
    def init({test_pid, release_delay}),
      do: {:ok, %{test_pid: test_pid, release_delay: release_delay}}

    @impl true
    def handle_call(:close, _from, state) do
      if state.release_delay do
        Process.send_after(self(), :release_close, state.release_delay)
      end

      receive do
        :release_close -> {:stop, :normal, :ok, state}
      end
    end
  end

  describe "make_symlink/3" do
    test "always returns enotsup" do
      assert {{:error, :enotsup}, _state} =
               FileHandler.make_symlink(~c"/src", ~c"/dst", @state)
    end
  end

  describe "read_link/2" do
    test "always returns einval" do
      assert {{:error, :einval}, _state} = FileHandler.read_link(~c"/path", @state)
    end
  end

  describe "write_file_info/3" do
    test "always returns ok" do
      assert {:ok, _state} = FileHandler.write_file_info(~c"/path", {}, @state)
    end
  end

  describe "get_cwd/1" do
    test "returns '/' and sets cwd when no cwd in state" do
      {{:ok, cwd}, new_state} = FileHandler.get_cwd(@state)
      assert cwd == ~c"/"
      assert new_state.cwd == ~c"/"
    end

    test "returns existing cwd when present" do
      state = Map.put(@state, :cwd, ~c"/home/user")
      {{:ok, cwd}, _new_state} = FileHandler.get_cwd(state)
      assert cwd == ~c"/home/user"
    end
  end

  describe "open/3" do
    test "falls back to read mode when no modes specified" do
      state = %{backend: MockBackend, backend_state: %{}}
      {{:ok, pid}, _state} = FileHandler.open(~c"/file.txt", [], state)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "close/2" do
    property "timed-out close can still finish cleanly within the cleanup grace" do
      check all(release_delay <- integer(25..50), max_runs: 10) do
        {:ok, pid} = ControlledCloseDevice.start(self(), release_delay)
        ref = Process.monitor(pid)

        capture_log(fn ->
          assert {{:error, :timeout}, _state} =
                   FileHandler.close(pid, %{
                     backend: nil,
                     backend_state: nil,
                     close_timeout: 1,
                     close_shutdown_grace: release_delay + 100
                   })
        end)

        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      end
    end

    test "returns timeout but allows a slow close to clean up during the grace window" do
      {:ok, pid} = ControlledCloseDevice.start(self(), 50)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          assert {{:error, :timeout}, _state} =
                   FileHandler.close(pid, %{
                     backend: nil,
                     backend_state: nil,
                     close_timeout: 10,
                     close_shutdown_grace: 200
                   })
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      assert log =~ "Timed out waiting 10ms"
    end

    test "does not leave late close replies in the caller mailbox after timeout" do
      {:ok, pid} = SlowCloseDevice.start()
      ref = Process.monitor(pid)

      capture_log(fn ->
        assert {{:error, :timeout}, _state} =
                 FileHandler.close(pid, %{
                   backend: nil,
                   backend_state: nil,
                   close_timeout: 10,
                   close_shutdown_grace: 200
                 })
      end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      Process.sleep(100)
      refute_received {_tag, :ok}
      refute_received {:ok, _}
    end

    test "kills the device when cleanup grace also expires" do
      {:ok, pid} = HangingCloseDevice.start()
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          assert {{:error, :timeout}, _state} =
                   FileHandler.close(pid, %{
                     backend: nil,
                     backend_state: nil,
                     close_timeout: 10,
                     close_shutdown_grace: 10
                   })
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
      assert log =~ "did not close within 10ms cleanup grace"
    end
  end
end
