defmodule Sftpd.Backends.S3Test do
  use ExUnit.Case, async: true

  import Mox

  alias Sftpd.Backends.S3
  alias Sftpd.Test.MockExAws

  setup :verify_on_exit!

  describe "parse_http_date/1" do
    test "parses valid RFC 1123 date" do
      assert {{1994, 11, 6}, {8, 49, 37}} = S3.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
    end

    test "parses date with different day of week" do
      assert {{2024, 1, 15}, {12, 30, 45}} = S3.parse_http_date("Mon, 15 Jan 2024 12:30:45 GMT")
    end

    test "parses all months correctly" do
      months = [
        {"Jan", 1},
        {"Feb", 2},
        {"Mar", 3},
        {"Apr", 4},
        {"May", 5},
        {"Jun", 6},
        {"Jul", 7},
        {"Aug", 8},
        {"Sep", 9},
        {"Oct", 10},
        {"Nov", 11},
        {"Dec", 12}
      ]

      for {month, num} <- months do
        date_string = "Sun, 01 #{month} 2024 00:00:00 GMT"
        assert {{2024, ^num, 1}, {0, 0, 0}} = S3.parse_http_date(date_string)
      end
    end

    test "returns current time for invalid format" do
      result = S3.parse_http_date("not a valid date")
      {date, time} = result

      # Should be a valid Erlang datetime (can be converted)
      assert {:ok, _} = NaiveDateTime.from_erl({date, time})

      # Year should be recent (not some arbitrary year from bad parsing)
      {year, _, _} = date
      current_year = NaiveDateTime.utc_now().year
      assert year >= current_year - 1 and year <= current_year + 1
    end

    test "returns current time for empty string" do
      result = S3.parse_http_date("")
      {date, time} = result

      # Should be a valid Erlang datetime
      assert {:ok, _} = NaiveDateTime.from_erl({date, time})

      # Year should be recent
      {year, _, _} = date
      current_year = NaiveDateTime.utc_now().year
      assert year >= current_year - 1 and year <= current_year + 1
    end

    test "returns current time for invalid month" do
      result = S3.parse_http_date("Sun, 01 Foo 2024 00:00:00 GMT")
      {date, time} = result

      # Should be a valid Erlang datetime
      assert {:ok, _} = NaiveDateTime.from_erl({date, time})

      # Year should be recent (not 2024 from the invalid input)
      {year, _, _} = date
      current_year = NaiveDateTime.utc_now().year
      assert year >= current_year - 1 and year <= current_year + 1
    end

    test "handles dates at midnight" do
      assert {{2024, 6, 15}, {0, 0, 0}} = S3.parse_http_date("Sat, 15 Jun 2024 00:00:00 GMT")
    end

    test "handles dates at end of day" do
      assert {{2024, 6, 15}, {23, 59, 59}} = S3.parse_http_date("Sat, 15 Jun 2024 23:59:59 GMT")
    end
  end

  describe "init/1" do
    test "requires bucket option" do
      assert_raise KeyError, fn ->
        S3.init([])
      end
    end

    test "extracts bucket from options" do
      {:ok, state} = S3.init(bucket: "my-bucket")
      assert state.bucket == "my-bucket"
    end

    test "defaults prefix to empty string" do
      {:ok, state} = S3.init(bucket: "my-bucket")
      assert state.prefix == ""
    end

    test "accepts custom prefix" do
      {:ok, state} = S3.init(bucket: "my-bucket", prefix: "tenant1/")
      assert state.prefix == "tenant1/"
    end

    test "defaults aws_client to ExAws" do
      {:ok, state} = S3.init(bucket: "my-bucket")
      assert state.aws_client == ExAws
    end

    test "accepts custom aws_client" do
      {:ok, state} = S3.init(bucket: "my-bucket", aws_client: MockExAws)
      assert state.aws_client == MockExAws
    end
  end

  describe "list_dir/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "root path lists top-level entries", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok, %{body: %{contents: [%{key: "file.txt"}, %{key: "dir/.keep"}, %{key: ".keep"}]}}}
      end)

      assert {:ok, listing} = S3.list_dir(~c"/", state)
      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"file.txt" in listing
      assert ~c"dir" in listing
      refute ~c".keep" in listing
    end

    test "root path handles S3 error gracefully", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :timeout} end)

      assert {:ok, listing} = S3.list_dir(~c"/", state)
      assert listing == [~c".", ~c".."]
    end

    test "subdirectory lists entries under prefix", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok,
         %{
           body: %{
             contents: [
               %{key: "subdir/file1.txt"},
               %{key: "subdir/nested/file2.txt"}
             ]
           }
         }}
      end)

      assert {:ok, listing} = S3.list_dir(~c"/subdir", state)
      assert ~c"file1.txt" in listing
      assert ~c"nested" in listing
    end

    test "subdirectory handles S3 error gracefully", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :network_error} end)

      assert {:ok, listing} = S3.list_dir(~c"/subdir", state)
      assert listing == [~c".", ~c".."]
    end

    test "root path /. is treated as root", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok, %{body: %{contents: [%{key: "top.txt"}]}}}
      end)

      assert {:ok, listing} = S3.list_dir(~c"/.", state)
      assert ~c"top.txt" in listing
    end
  end

  describe "file_info/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "root path always returns directory info", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/", state)
    end

    test "existing file returns file info with size and mtime", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok,
         %{
           headers: [
             {"Content-Length", "42"},
             {"Last-Modified", "Mon, 15 Jan 2024 12:30:45 GMT"}
           ]
         }}
      end)

      assert {:ok, {:file_info, 42, :regular, :read_write, mtime, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/file.txt", state)

      assert mtime == {{2024, 1, 15}, {12, 30, 45}}
    end

    test "existing file with missing headers uses defaults", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok, %{headers: []}}
      end)

      assert {:ok, {:file_info, 0, :regular, :read_write, _, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/file.txt", state)
    end

    test "directory returns directory info via listing", %{state: state} do
      # head_object fails
      expect(MockExAws, :request, fn _op -> {:error, :not_found} end)
      # check_directory_exists finds objects
      expect(MockExAws, :request, fn _op ->
        {:ok, %{body: %{contents: [%{key: "dir/file.txt"}]}}}
      end)

      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/dir", state)
    end

    test "non-existent path returns enoent", %{state: state} do
      # head_object fails
      expect(MockExAws, :request, fn _op -> {:error, :not_found} end)
      # check_directory_exists finds nothing
      expect(MockExAws, :request, fn _op ->
        {:ok, %{body: %{contents: []}}}
      end)

      assert {:error, :enoent} = S3.file_info(~c"/nonexistent", state)
    end
  end

  describe "make_dir/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "creates .keep marker on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)

      assert :ok = S3.make_dir(~c"/newdir", state)
    end

    test "returns eacces on failure", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :forbidden} end)

      assert {:error, :eacces} = S3.make_dir(~c"/newdir", state)
    end
  end

  describe "del_dir/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "deletes .keep marker on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)

      assert :ok = S3.del_dir(~c"/dir", state)
    end

    test "returns enoent on 404", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 404, %{}}} end)

      assert {:error, :enoent} = S3.del_dir(~c"/dir", state)
    end

    test "returns eio on other errors", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 500, %{}}} end)

      assert {:error, :eio} = S3.del_dir(~c"/dir", state)
    end
  end

  describe "delete/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "deletes object on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)

      assert :ok = S3.delete(~c"/file.txt", state)
    end

    test "returns error on failure", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :forbidden} end)

      assert {:error, :forbidden} = S3.delete(~c"/file.txt", state)
    end
  end

  describe "rename/3 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "copies then deletes on success", %{state: state} do
      # copy
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)
      # delete
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)

      assert :ok = S3.rename(~c"/old.txt", ~c"/new.txt", state)
    end

    test "returns enoent when copy fails", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :not_found} end)

      assert {:error, :enoent} = S3.rename(~c"/old.txt", ~c"/new.txt", state)
    end
  end

  describe "read_file/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "returns file content on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{body: "hello world"}} end)

      assert {:ok, "hello world"} = S3.read_file(~c"/file.txt", state)
    end

    test "returns enoent on 404", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 404, %{}}} end)

      assert {:error, :enoent} = S3.read_file(~c"/missing.txt", state)
    end

    test "returns eio on other errors", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 503, %{}}} end)

      assert {:error, :eio} = S3.read_file(~c"/file.txt", state)
    end
  end

  describe "write_file/3 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "puts object on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)

      assert :ok = S3.write_file(~c"/file.txt", "content", state)
    end

    test "returns error on failure", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :quota_exceeded} end)

      assert {:error, :quota_exceeded} = S3.write_file(~c"/file.txt", "content", state)
    end
  end

  describe "prefix support" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", prefix: "tenant/", aws_client: MockExAws)
      %{state: state}
    end

    test "list_dir strips prefix from results", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok, %{body: %{contents: [%{key: "tenant/file.txt"}, %{key: "tenant/dir/.keep"}]}}}
      end)

      assert {:ok, listing} = S3.list_dir(~c"/", state)
      assert ~c"file.txt" in listing
      assert ~c"dir" in listing
    end

    test "file_info uses prefix in key", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok, %{headers: [{"Content-Length", "10"}]}}
      end)

      assert {:ok, {:file_info, 10, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/file.txt", state)
    end
  end
end
