defmodule SftpdS3.S3.OperationsTest do
  use ExUnit.Case, async: false

  doctest SftpdS3.S3.Operations

  alias SftpdS3.S3.Operations

  describe "Directory operations" do
    setup do
      bucket = "directory-operations-#{:rand.uniform(100_000)}"

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

    test "list_dir returns . and .. for empty bucket", %{bucket: bucket} do
      assert [~c".", ~c".."] = Operations.list_dir("/", bucket)
    end

    test "list_dir returns top-level directories", %{bucket: bucket} do
      # Create some files in different directories
      ExAws.S3.put_object(bucket, "folder1/file.txt", "content") |> ExAws.request!()
      ExAws.S3.put_object(bucket, "folder2/file.txt", "content") |> ExAws.request!()

      listing = Operations.list_dir(~c"/", bucket)
      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"folder1" in listing
      assert ~c"folder2" in listing
    end

    test "list_dir returns contents of subdirectory", %{bucket: bucket} do
      ExAws.S3.put_object(bucket, "parent/child1/file.txt", "content") |> ExAws.request!()
      ExAws.S3.put_object(bucket, "parent/child2/file.txt", "content") |> ExAws.request!()
      ExAws.S3.put_object(bucket, "parent/file.txt", "content") |> ExAws.request!()

      listing = Operations.list_dir(~c"/parent", bucket)
      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"child1" in listing
      assert ~c"child2" in listing
      assert ~c"file.txt" in listing
    end

    test "make_dir creates directory with .keep marker", %{bucket: bucket} do
      assert [~c".", ~c".."] = Operations.list_dir(~c"/", bucket)
      assert :ok = Operations.make_dir(~c"/new_dir", bucket)

      # Verify .keep file exists
      {:ok, _} = ExAws.S3.head_object(bucket, "new_dir/.keep") |> ExAws.request()

      listing = Operations.list_dir(~c"/", bucket)
      assert ~c"new_dir" in listing
    end

    test "del_dir removes directory .keep marker", %{bucket: bucket} do
      Operations.make_dir(~c"/temp_dir", bucket)

      listing = Operations.list_dir(~c"/", bucket)
      assert ~c"temp_dir" in listing

      assert :ok = Operations.del_dir(~c"/temp_dir", bucket)

      # .keep should be gone
      {:error, _} = ExAws.S3.head_object(bucket, "temp_dir/.keep") |> ExAws.request()
    end
  end

  describe "read_link_info" do
    setup do
      bucket = "read-link-info-#{:rand.uniform(100_000)}"

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

    test "returns directory info for /", %{bucket: bucket} do
      assert {:ok,
              {:file_info, 640, :directory, :read, _, _, _, 16877, 20, 16_777_230, 0, 2, 1, 1}} =
               Operations.read_link_info(~c"/", bucket)
    end

    test "returns directory info for /.", %{bucket: bucket} do
      assert {:ok, {:file_info, 640, :directory, :read, _, _, _, _, _, _, _, _, _, _}} =
               Operations.read_link_info(~c"/.", bucket)
    end

    test "returns directory info for /..", %{bucket: bucket} do
      assert {:ok, {:file_info, 640, :directory, :read, _, _, _, _, _, _, _, _, _, _}} =
               Operations.read_link_info(~c"/..", bucket)
    end

    test "returns directory info for paths ending in /.", %{bucket: bucket} do
      ExAws.S3.put_object(bucket, "folder/file.txt", "content") |> ExAws.request!()

      assert {:ok, {:file_info, 640, :directory, :read, _, _, _, _, _, _, _, _, _, _}} =
               Operations.read_link_info(~c"/folder/.", bucket)
    end

    test "returns directory info for paths ending in /..", %{bucket: bucket} do
      ExAws.S3.put_object(bucket, "folder/file.txt", "content") |> ExAws.request!()

      assert {:ok, {:file_info, 640, :directory, :read, _, _, _, _, _, _, _, _, _, _}} =
               Operations.read_link_info(~c"/folder/..", bucket)
    end

    test "returns file info for existing file", %{bucket: bucket} do
      content = "test file content"
      ExAws.S3.put_object(bucket, "test_file.txt", content) |> ExAws.request!()

      assert {:ok, {:file_info, size, :regular, :read_write, _, _, _, 33261, 1, 0, 0, _, 1, 1}} =
               Operations.read_link_info(~c"/test_file.txt", bucket)

      assert size == byte_size(content)
    end

    test "returns directory info for virtual directories (prefix with contents)", %{
      bucket: bucket
    } do
      ExAws.S3.put_object(bucket, "virtual_dir/file.txt", "content") |> ExAws.request!()

      assert {:ok, {:file_info, 640, :directory, :read, _, _, _, _, _, _, _, _, _, _}} =
               Operations.read_link_info(~c"/virtual_dir", bucket)
    end

    test "returns error for non-existent file", %{bucket: bucket} do
      assert {:error, :enoent} = Operations.read_link_info(~c"/nonexistent.txt", bucket)
    end

    test "returns error for non-existent directory without contents", %{bucket: bucket} do
      assert {:error, :enoent} = Operations.read_link_info(~c"/nonexistent_dir", bucket)
    end
  end

  describe "File operations" do
    setup do
      bucket = "file-operations-#{:rand.uniform(100_000)}"

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

    test "delete removes file", %{bucket: bucket} do
      ExAws.S3.put_object(bucket, "to_delete.txt", "content") |> ExAws.request!()

      assert :ok = Operations.delete(~c"/to_delete.txt", bucket)

      # Verify file is gone
      {:error, _} = ExAws.S3.head_object(bucket, "to_delete.txt") |> ExAws.request()
    end

    test "delete returns ok even for non-existent files", %{bucket: bucket} do
      # S3 delete is idempotent
      assert :ok = Operations.delete(~c"/nonexistent.txt", bucket)
    end

    test "rename moves file to new location", %{bucket: bucket} do
      ExAws.S3.put_object(bucket, "original.txt", "content") |> ExAws.request!()

      assert :ok = Operations.rename(~c"/original.txt", ~c"/renamed.txt", bucket)

      # Old file should be gone
      {:error, _} = ExAws.S3.head_object(bucket, "original.txt") |> ExAws.request()

      # New file should exist
      {:ok, %{body: body}} = ExAws.S3.get_object(bucket, "renamed.txt") |> ExAws.request()
      assert body == "content"
    end

    test "rename preserves file content", %{bucket: bucket} do
      content = "important content to preserve"
      ExAws.S3.put_object(bucket, "source.txt", content) |> ExAws.request!()

      Operations.rename(~c"/source.txt", ~c"/destination.txt", bucket)

      {:ok, %{body: body}} = ExAws.S3.get_object(bucket, "destination.txt") |> ExAws.request()
      assert body == content
    end

    test "read_stream returns enumerable for file", %{bucket: bucket} do
      content = "stream test content"
      ExAws.S3.put_object(bucket, "stream_test.txt", content) |> ExAws.request!()

      stream = Operations.read_stream("stream_test.txt", bucket)
      result = stream |> Enum.join()

      assert result == content
    end
  end

  describe "fake_directory_info" do
    test "returns valid file_info tuple" do
      info = Operations.fake_directory_info()

      assert {:file_info, 640, :directory, :read, _, _, _, 16877, 20, 16_777_230, 0, 2, 1, 1} =
               info
    end

    test "returns current timestamp" do
      {:file_info, _, _, _, {date, _time}, _, _, _, _, _, _, _, _, _} =
        Operations.fake_directory_info()

      today = Date.utc_today()
      assert date == {today.year, today.month, today.day}
    end
  end
end
