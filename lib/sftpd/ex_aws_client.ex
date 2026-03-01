defmodule Sftpd.ExAwsClient do
  @moduledoc false

  @callback request(op :: term()) :: {:ok, term()} | {:error, term()}
end
