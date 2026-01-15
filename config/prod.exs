import Config

# Production configuration
# Set these via environment variables or runtime config

config :sftpd,
  bucket: {:system, "SFTPD_BUCKET"}

config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: {:system, "AWS_REGION", "us-east-1"}
