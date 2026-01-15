defmodule Sftpd.Backends.S3Test do
  use ExUnit.Case, async: true

  alias Sftpd.Backends.S3

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
  end
end
