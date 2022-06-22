import Config

# TODO: only config this stuff for tests.

aws_uri =
  System.get_env("AWS_ENDPOINT_URL", "http://localhost:4566")
  |> URI.parse()

config :ex_aws, :s3,
  scheme: aws_uri.scheme,
  host: aws_uri.host,
  port: aws_uri.port
