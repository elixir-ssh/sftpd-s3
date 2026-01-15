defmodule Sftpd.Backends.MemoryTest do
  use ExUnit.Case, async: true

  alias Sftpd.Backends.Memory

  setup do
    {:ok, state} = Memory.init([])
    %{state: state}
  end

  describe "init/1" do
    test "starts with empty storage" do
      {:ok, state} = Memory.init([])
      assert {:ok, [~c".", ~c".."]} = Memory.list_dir(~c"/", state)
    end

    test "can be initialized with files" do
      {:ok, state} =
        Memory.init(
          files: %{
            "test.txt" => %{content: "hello", mtime: ~N[2024-01-01 00:00:00]}
          }
        )

      assert {:ok, [~c".", ~c"..", ~c"test.txt"]} = Memory.list_dir(~c"/", state)
    end
  end

  describe "file operations" do
    test "write and read file", %{state: state} do
      assert :ok = Memory.write_file(~c"/test.txt", "hello world", state)
      assert {:ok, "hello world"} = Memory.read_file(~c"/test.txt", state)
    end

    test "read non-existent file returns error", %{state: state} do
      assert {:error, :enoent} = Memory.read_file(~c"/nonexistent.txt", state)
    end

    test "delete file", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)
      assert :ok = Memory.delete(~c"/test.txt", state)
      assert {:error, :enoent} = Memory.read_file(~c"/test.txt", state)
    end

    test "rename file", %{state: state} do
      Memory.write_file(~c"/old.txt", "content", state)
      assert :ok = Memory.rename(~c"/old.txt", ~c"/new.txt", state)
      assert {:error, :enoent} = Memory.read_file(~c"/old.txt", state)
      assert {:ok, "content"} = Memory.read_file(~c"/new.txt", state)
    end
  end

  describe "directory operations" do
    test "make and list directory", %{state: state} do
      assert :ok = Memory.make_dir(~c"/mydir", state)
      assert {:ok, listing} = Memory.list_dir(~c"/", state)
      assert ~c"mydir" in listing
    end

    test "delete directory", %{state: state} do
      Memory.make_dir(~c"/mydir", state)
      assert :ok = Memory.del_dir(~c"/mydir", state)
      assert {:ok, [~c".", ~c".."]} = Memory.list_dir(~c"/", state)
    end

    test "list files in subdirectory", %{state: state} do
      Memory.make_dir(~c"/subdir", state)
      Memory.write_file(~c"/subdir/file1.txt", "a", state)
      Memory.write_file(~c"/subdir/file2.txt", "b", state)

      assert {:ok, listing} = Memory.list_dir(~c"/subdir", state)
      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"file1.txt" in listing
      assert ~c"file2.txt" in listing
    end
  end

  describe "root path variants" do
    test "list_dir with '.' returns root", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)
      assert {:ok, listing} = Memory.list_dir(~c".", state)
      assert ~c"test.txt" in listing
    end

    test "list_dir with empty path returns root", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)
      assert {:ok, listing} = Memory.list_dir(~c"", state)
      assert ~c"test.txt" in listing
    end

    test "file_info with '.' returns directory", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c".", state)
    end

    test "file_info with empty path returns directory", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"", state)
    end
  end

  describe "file_info" do
    test "root is always a directory", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"/", state)
    end

    test "file returns regular type", %{state: state} do
      Memory.write_file(~c"/test.txt", "hello", state)

      assert {:ok, {:file_info, 5, :regular, :read_write, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"/test.txt", state)
    end

    test "directory returns directory type", %{state: state} do
      Memory.make_dir(~c"/mydir", state)

      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               Memory.file_info(~c"/mydir", state)
    end

    test "non-existent returns error", %{state: state} do
      assert {:error, :enoent} = Memory.file_info(~c"/nonexistent", state)
    end
  end
end
