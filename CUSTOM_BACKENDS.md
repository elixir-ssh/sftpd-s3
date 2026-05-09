# Custom Backends

This guide explains how to build your own backend for `Sftpd`.

If you only need a built-in backend, see `BACKENDS.md`. If you want the exact
callback contracts, see `Sftpd.Backend`.

## Backend Model

`Sftpd` asks a backend to present a filesystem-like interface over some storage
system. That storage can be:

- a local service API
- object storage
- a database
- an in-memory structure
- a process that fronts another system

Your backend does not need to be a real filesystem, but it does need to act
like one from the SFTP client's point of view.

## Required Callbacks

Every backend must implement:

- `init/1`
- `list_dir/2`
- `file_info/2`
- `make_dir/2`
- `del_dir/2`
- `delete/2`
- `rename/3`
- `read_file/2`
- `write_file/3`

Those callbacks are enough for a working backend, even if the underlying
implementation is simplistic.

## Minimal Example

```elixir
defmodule MyApp.ExampleBackend do
  @behaviour Sftpd.Backend

  @impl true
  def init(opts) do
    {:ok, %{root: Keyword.fetch!(opts, :root)}}
  end

  @impl true
  def list_dir(_path, _state) do
    {:ok, [~c".", ~c".."]}
  end

  @impl true
  def file_info(_path, _state) do
    {:error, :enoent}
  end

  @impl true
  def make_dir(_path, _state), do: :ok

  @impl true
  def del_dir(_path, _state), do: :ok

  @impl true
  def delete(_path, _state), do: :ok

  @impl true
  def rename(_src, _dst, _state), do: :ok

  @impl true
  def read_file(_path, _state), do: {:error, :enoent}

  @impl true
  def write_file(_path, _content, _state), do: :ok
end
```

## Returning File Metadata

`file_info/2` must return Erlang-style file metadata tuples. In practice you
should use the helpers in `Sftpd.Backend` instead of constructing them by hand:

- `Sftpd.Backend.file_info/3`
- `Sftpd.Backend.directory_info/0`

Example:

```elixir
{:ok, Sftpd.Backend.file_info(byte_size(content), NaiveDateTime.to_erl(mtime))}
```

For root-like paths, make sure you return directory metadata rather than
`{:error, :enoent}`.

## Path Handling

SFTP paths arrive as charlists. Common helpers:

- `Sftpd.Backend.root_path?/1`
- `Sftpd.Backend.normalize_path/1`

`normalize_path/1` is especially useful for key-based stores such as S3-like
systems because it removes the leading `/`.

## Directory Listings

`list_dir/2` must return entries as charlists and must include:

- `~c"."`
- `~c".."`

Even if the backing store does not have explicit directory entries, the SFTP
layer expects those names to exist.

## Error Conventions

Prefer POSIX-style atoms:

- `:enoent` for missing files or directories
- `:eacces` for permission failures
- `:einval` for invalid requests
- `:eio` for unexpected storage failures

Using stable error atoms matters because SFTP clients map them to user-visible
status codes.

## Optional Streaming Callbacks

For better large-file performance, module backends can also implement:

- `read_file_range/4`
- `begin_write/2`
- `write_chunk/4`
- `finish_write/2`
- `abort_write/2`

These callbacks are optional, but valuable when:

- whole-file reads are too expensive
- uploads should stream rather than buffer
- multipart writes are supported by the target storage

If you do not implement them, `Sftpd` falls back to the required callbacks.

## Process-Based Backends

If your backend already lives inside a GenServer, you can provide:

```elixir
backend: {:genserver, MyApp.BackendServer}
```

In that mode, `Sftpd` does not call `init/1`. Instead it sends `handle_call/3`
messages corresponding to the required backend operations.

This is useful when:

- the backend owns pooled connections
- the backend has mutable shared state
- the backend is already part of your supervision tree

## Testing Recommendations

At minimum, test:

- root listing behavior
- missing path behavior
- file metadata shape
- write then read round-trips
- rename semantics
- directory creation and deletion

If you implement streaming callbacks, also test:

- sequential reads through `read_file_range/4`
- sequential writes through `write_chunk/4`
- finalization and abort paths
- non-sequential write fallback behavior if relevant

## Telemetry

Backend activity is visible through `Sftpd` telemetry events emitted around
server lifecycle and SFTP file-handler operations. See `TELEMETRY.md` for the
event catalog and metadata.

## Next Steps

- See `Sftpd.Backend` for the exact callback contracts
- See `BACKENDS.md` for tradeoffs between built-in and custom backends
- See `Sftpd.Backends.Memory` for a simple reference implementation
- See `Sftpd.Backends.S3` for a streaming-capable reference implementation
