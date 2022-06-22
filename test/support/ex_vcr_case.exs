defmodule SftpdS3.ExVCRCase do
  @moduledoc """
  This module defines test cases that are recorded by ExVCR.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExVCR.Mock
    end
  end

  setup do
    ExVCR.Config.cassette_library_dir("fixture/vcr_cassettes")
    :ok
  end
end
