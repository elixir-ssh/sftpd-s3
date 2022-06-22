defmodule SftpdS3.S3.OperationsTest do
  use ExUnit.Case, async: true

  doctest SftpdS3

  alias SftpdS3.S3.Operations

  setup do
    ExAws.S3.put_bucket("operations-test-bucket", "us-east-1")
    |> ExAws.request!()

    :ok
  end

  test "list empty dir" do
    ExAws.S3.put_bucket("list-empty-dir", "us-east-1")
    |> ExAws.request!()

    assert true
  end
end
