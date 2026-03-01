defmodule Sftpd.FileHandlerTest do
  use ExUnit.Case, async: true

  alias Sftpd.FileHandler

  @state %{backend: nil, backend_state: nil}

  defmodule MockBackend do
    def read_file(_path, _state), do: {:ok, "content"}
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
end
