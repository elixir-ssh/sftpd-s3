defmodule SftpdS3.S3.OperationsTest do
  use ExUnit.Case, async: true

  doctest SftpdS3.S3.Operations

  alias SftpdS3.S3.Operations

  describe "Directory operations" do
    setup do
      bucket = "directory-operations"

      ExAws.S3.put_bucket(bucket, "us-east-1")
      |> ExAws.request!()

      on_exit(fn ->
        bucket
        |> ExAws.S3.list_objects()
        |> ExAws.stream!()
        |> Enum.each(&ExAws.request!(ExAws.S3.delete_object(bucket, &1.key)))

        ExAws.S3.delete_bucket(bucket) |> ExAws.request()
      end)

      %{bucket: bucket}
    end

    test "list_dir", %{bucket: bucket} do
      assert [~c".", ~c".."] = Operations.list_dir("/", bucket)
    end

    test "make_dir", %{bucket: bucket} do
      assert [~c".", ~c".."] = Operations.list_dir(~c"/", bucket)
      assert :ok = Operations.make_dir(~c"/make_dir", bucket)
      assert [~c"make_dir", ~c".", ~c".."] = Operations.list_dir(~c"/", bucket)
    end

    test "read_link_info /", %{bucket: bucket} do
      assert {:ok,
              {:file_info, 640, :directory, :read, time, time, time, 16877, 20, 16_777_230, 0, 2,
               1, 1}} = Operations.read_link_info(~c"/", bucket)
    end
  end

  describe "File operations" do
    setup do
      bucket = "file-operations"

      ExAws.S3.put_bucket(bucket, "us-east-1")
      |> ExAws.request!()

      on_exit(fn ->
        bucket
        |> ExAws.S3.list_objects()
        |> ExAws.stream!()
        |> Enum.each(&ExAws.request!(ExAws.S3.delete_object(bucket, &1.key)))

        ExAws.S3.delete_bucket(bucket) |> ExAws.request()
      end)

      %{bucket: bucket}
    end

    test "read_link_info /file", %{bucket: bucket} do
      ExAws.S3.put_object(bucket, "file", "some text") |> ExAws.request!()

      # TODO: size should be 9
      assert {:ok,
              {:file_info, 0, :regular, :read_write, time, time, time, 33261, 1, 0, 0, _, 1, 1}} =
               Operations.read_link_info(~c"/file", bucket)
    end
  end
end
