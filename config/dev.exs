import Config

config :sftpd,
  bucket: "sftpd-s3-dev-bucket"

# ExAws configuration for development
# Configure these for your S3-compatible endpoint
config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: "us-west-2"
