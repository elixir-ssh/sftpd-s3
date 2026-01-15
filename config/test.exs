import Config

# Keep debug logs available - tests can use capture_log to suppress
config :logger, level: :debug

# LocalStack S3 configuration for tests
aws_uri =
  System.get_env("AWS_ENDPOINT_URL", "http://localhost:4566")
  |> URI.parse()

config :ex_aws,
  access_key_id: "",
  secret_access_key: ""

config :ex_aws, :s3,
  scheme: aws_uri.scheme <> "://",
  host: aws_uri.host,
  port: aws_uri.port

# S3 backend configuration for tests
config :sftpd,
  bucket: "sftpd-s3-test-bucket"
