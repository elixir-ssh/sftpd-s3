defmodule SftpdS3Test do
  use ExUnit.Case, async: true

  doctest SftpdS3

  setup do
    :ok
  end

  test "greets the world" do
    assert SftpdS3.hello() == :world
  end
end
