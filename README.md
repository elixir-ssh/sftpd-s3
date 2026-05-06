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
The built-in S3 backend now uses range reads, paginated delimiter-based
directory listings, and multipart streaming writes for better large-file
performance.

```elixir
Sftpd.start_server(
  port: 2222,
  backend: Sftpd.Backends.S3,
  backend_opts: [bucket: "my-bucket", prefix: "tenant-a/"],
  users: [{"user", "pass"}],
  system_dir: "/path/to/ssh_host_keys"
)
```

`backend_opts` supports:

- `:bucket` - required S3 bucket name
- `:prefix` - optional key prefix for namespacing objects within a bucket
- `:aws_client` - optional ExAws-compatible client module, mainly useful for tests or custom request adapters

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

### Optional Streaming Backend Callbacks

Custom module backends can implement optional callbacks for efficient large-file
transfers:

```elixir
# read_file_range(path, offset, len, state) -> {:ok, binary} | :eof | {:error, reason}
# begin_write(path, state) -> {:ok, writer_handle} | {:error, reason}
# write_chunk(writer_handle, offset, chunk, state) -> {:ok, writer_handle} | {:error, reason}
# finish_write(writer_handle, state) -> :ok | {:error, reason}
# abort_write(writer_handle, state) -> :ok
```

These callbacks let `Sftpd.IODevice` avoid loading whole files into memory on
open and reduce write-side buffering. See `Sftpd.Backend` for the exact
callback contracts.

Note that OTP's built-in `:ssh_sftpd` implementation always reports success for
close operations, even if final close-time flushing fails. Write errors are
therefore surfaced during active writes whenever possible, while close-only
failures are logged server-side.

If you need to bound how long close-time finalization can block a session, pass
`close_timeout: timeout_in_ms` to `Sftpd.start_server/1`. The default is
`30_000`.

## Telemetry

`Sftpd` emits `:telemetry` events for server lifecycle and SFTP operations.
Telemetry support is optional: if the `:telemetry` module is unavailable at
runtime, event emission is skipped and the SFTP server continues normally.

If you want to attach handlers from an application that does not already depend
on `:telemetry`, add it explicitly:

```elixir
def deps do
  [
    {:telemetry, ">= 0.4.3 and < 2.0.0"},
    {:sftpd, "~> 0.2.0"}
  ]
end
```

- `[:sftpd, :server, :start]`
- `[:sftpd, :server, :stop]`
- `[:sftpd, :sftp, operation]` where `operation` is one of `:open`, `:close`,
  `:read`, `:write`, `:list_dir`, `:read_file_info`, `:read_link_info`,
  `:rename`, `:delete`, `:make_dir`, `:del_dir`, `:position`, `:is_dir`,
  `:get_cwd`, `:make_symlink`, `:read_link`, or `:write_file_info`

Every event includes `%{duration: native_time}` measurements. `:read` and
`:write` also include `:bytes`.

Common metadata for `[:sftpd, :sftp, operation]` events:

- `:backend` and `:backend_kind` identify the configured backend
- `:result` is usually `:ok`, `:error`, or `:eof`
- `:reason` is present on error results when one is available

Operation-specific metadata:

- `:open` adds `:path`, `:requested_modes`, and normalized `:mode`
- `:close` adds `:io_device`, `:close_timeout`, and `:close_shutdown_grace`
- `:read` adds `:io_device` and `:bytes_requested`
- `:write` adds `:io_device`
- path-oriented operations add `:path`
- `:rename` adds `:src_path` and `:dst_path`
- `:position` adds `:io_device` and `:offset`
- `:is_dir` reports `:result` as `:directory` or `:not_directory`

Server lifecycle metadata:

- `[:sftpd, :server, :start]` includes `:port`, `:max_sessions`, `:backend`,
  `:backend_kind`, `:result`, and `:server_ref` on success
- `[:sftpd, :server, :stop]` includes `:server_ref` and `:result`

```elixir
:telemetry.attach(
  "sftpd-read-logger",
  [:sftpd, :sftp, :read],
  fn _event, measurements, metadata, _config ->
    Logger.info("sftp read #{metadata.path} bytes=#{measurements.bytes} result=#{metadata.result}")
  end,
  nil
)
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
