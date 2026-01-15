# Sftpd

A pluggable SFTP server for Elixir with support for S3 and custom backends.

## Installation

```elixir
def deps do
  [
    {:sftpd, "~> 0.2.0"}
  ]
end
```

## Quick Start

```elixir
# Start with in-memory backend (great for development)
{:ok, pid} = Sftpd.start_server(
  port: 2222,
  backend: Sftpd.Backends.Memory,
  backend_opts: [],
  users: [{"dev", "dev"}],
  system_dir: "/path/to/ssh_host_keys"
)

# Connect with: sftp -P 2222 dev@localhost
```

## Backends

### Memory Backend

Stores files in memory. Useful for development and testing without external dependencies.

```elixir
Sftpd.start_server(
  port: 2222,
  backend: Sftpd.Backends.Memory,
  backend_opts: [],
  users: [{"user", "pass"}],
  system_dir: "/path/to/ssh_host_keys"
)
```

### S3 Backend

Stores files in Amazon S3 or S3-compatible storage (LocalStack, MinIO, etc.).

```elixir
Sftpd.start_server(
  port: 2222,
  backend: Sftpd.Backends.S3,
  backend_opts: [bucket: "my-bucket"],
  users: [{"user", "pass"}],
  system_dir: "/path/to/ssh_host_keys"
)
```

Configure ExAws for your S3 endpoint:

```elixir
# config/config.exs
config :ex_aws,
  access_key_id: "your-key",
  secret_access_key: "your-secret",
  region: "us-east-1"

# For LocalStack
config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 4566
```

### Custom Backends

Implement the `Sftpd.Backend` behaviour to create custom storage backends.

## SSH Host Keys

Generate SSH host keys for your server:

```bash
mkdir -p ssh_keys
ssh-keygen -t rsa -f ssh_keys/ssh_host_rsa_key -N ""
ssh-keygen -t ecdsa -f ssh_keys/ssh_host_ecdsa_key -N ""
ssh-keygen -t ed25519 -f ssh_keys/ssh_host_ed25519_key -N ""
```

Then pass the directory to `system_dir`:

```elixir
Sftpd.start_server(
  # ...
  system_dir: "ssh_keys"
)
```

## Documentation

Full documentation available at [HexDocs](https://hexdocs.pm/sftpd).

## License

Apache 2.0
