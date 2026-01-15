defmodule SftpdS3.S3.IODeviceTest do
  use ExUnit.Case, async: false

  alias SftpdS3.S3.IODevice

  @bucket "io-device-test-bucket"

  setup do
    ExAws.S3.put_bucket(@bucket, "us-east-1") |> ExAws.request()

    on_exit(fn ->
      @bucket
      |> ExAws.S3.list_objects()
      |> ExAws.stream!()
      |> Enum.each(&ExAws.request!(ExAws.S3.delete_object(@bucket, &1.key)))

      ExAws.S3.delete_bucket(@bucket) |> ExAws.request()
    end)

    :ok
  end

  describe "read mode" do
    test "starts successfully for existing file" do
      ExAws.S3.put_object(@bucket, "test_read.txt", "hello world") |> ExAws.request!()

      assert {:ok, pid} =
               IODevice.start(%{
                 path: ~c"/test_read.txt",
                 bucket: @bucket,
                 mode: :read
               })

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "reads entire file content correctly" do
      content = "test content for reading"
      ExAws.S3.put_object(@bucket, "read_content.txt", content) |> ExAws.request!()

      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/read_content.txt",
          bucket: @bucket,
          mode: :read
        })

      Process.sleep(100)

      # Read the full file
      assert {:ok, result} = GenServer.call(pid, {:read, byte_size(content)})
      assert result == content

      GenServer.stop(pid)
    end

    test "returns eof for empty file" do
      ExAws.S3.put_object(@bucket, "empty.txt", "") |> ExAws.request!()

      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/empty.txt",
          bucket: @bucket,
          mode: :read
        })

      Process.sleep(100)

      assert :eof = GenServer.call(pid, {:read, 10})

      GenServer.stop(pid)
    end

    test "position call returns ok" do
      ExAws.S3.put_object(@bucket, "position_test.txt", "content") |> ExAws.request!()

      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/position_test.txt",
          bucket: @bucket,
          mode: :read
        })

      Process.sleep(100)

      assert {:ok, 0} = GenServer.call(pid, {:position, {:bof, 0}})

      GenServer.stop(pid)
    end
  end

  describe "write mode" do
    test "starts successfully for new file" do
      assert {:ok, pid} =
               IODevice.start(%{
                 path: ~c"/new_write_file.txt",
                 bucket: @bucket,
                 mode: :write
               })

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "write call returns ok" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/write_test.txt",
          bucket: @bucket,
          mode: :write
        })

      Process.sleep(100)

      assert :ok = GenServer.call(pid, {:write, "hello from test"})

      GenServer.stop(pid)
    end

    test "position in write mode returns ok" do
      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/position_write.txt",
          bucket: @bucket,
          mode: :write
        })

      Process.sleep(100)

      assert {:ok, 0} = GenServer.call(pid, {:position, {:bof, 0}})

      GenServer.stop(pid)
    end
  end

  describe "edge cases" do
    test "handles binary content" do
      binary_content = <<0, 1, 2, 3, 255, 254, 253>>
      ExAws.S3.put_object(@bucket, "binary.bin", binary_content) |> ExAws.request!()

      {:ok, pid} =
        IODevice.start(%{
          path: ~c"/binary.bin",
          bucket: @bucket,
          mode: :read
        })

      Process.sleep(100)

      {:ok, result} = GenServer.call(pid, {:read, byte_size(binary_content)})
      assert result == binary_content

      GenServer.stop(pid)
    end
  end
end
