# CLAUDE.md

## Project Overview

SftpdS3 is an Elixir library that provides an SFTP server backed by S3 storage. It implements a file handler for OTP's `:ssh_sftpd` subsystem, providing virtual access to an S3 bucket.

## Architecture

- `lib/sftpd_s3.ex` - Main module, starts the SSH daemon
- `lib/sftpd_s3/s3/file_handler.ex` - Implements `:ssh_sftpd_file_api` behaviour
- `lib/sftpd_s3/s3/io_device.ex` - GenServer managing file handles for read/write operations
- `lib/sftpd_s3/s3/operations.ex` - S3 operations wrapper (list, read, write, delete, rename)

## Development

### Prerequisites

- Erlang/OTP 28+
- Elixir 1.19+
- LocalStack for local S3 testing

### Version Management

**Important:** `flake.nix` and `.tool-versions` must stay in sync. When updating Erlang or Elixir versions, update both files.

### Running Tests

```bash
# Start LocalStack first
docker-compose up -d

# Run tests
mix test
```

Tests use LocalStack as the S3 backend. The bucket `sftpd-s3-test-bucket` is used for integration tests.

### Manual Testing

```bash
./test_sftp.sh
# or
mix run test_manual.exs
```

## S3 Constraints

- S3 multipart uploads require minimum 5MB per part
- Small file writes use single-part uploads via the terminate callback
- Directories are virtual (represented by `.keep` marker files)

## Configuration

Set in `config/config.exs` or `config/test.exs`:

- `:bucket` - S3 bucket name
- ExAws configuration for S3 endpoint (LocalStack uses `http://localhost:4566`)
