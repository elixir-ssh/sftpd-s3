defmodule SftpdS3.S3.IODevice do
  use GenServer

  alias SftpdS3.S3.Operations

  require Logger

  @spec start_link(map) :: GenServer.on_start()
  def start_link(opts) do
    # Use start instead of start_link to avoid crashing the channel
    # when this GenServer terminates
    GenServer.start(__MODULE__, opts)
  end

  @impl GenServer
  @spec init(%{:bucket => String.t(), :path => charlist(), optional(:mode) => :read | :write}) ::
          {:ok, %{bucket: any, path: any, mode: :read | :write}, {:continue, :open}}
  def init(%{path: path, bucket: bucket, mode: mode}) do
    {:ok, %{path: path, bucket: bucket, mode: mode}, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, %{path: path, bucket: bucket, mode: :read}) do
    case Operations.read_link_info(path, bucket) do
      {:ok, fi} ->
        size = fi |> elem(1)

        {:noreply,
         %{
           mode: :read,
           position: 0,
           size: size,
           path: path,
           bucket: bucket,
           stream: Operations.read_stream(path |> to_string(), bucket)
         }}

      {:error, _} ->
        # File doesn't exist
        {:noreply,
         %{
           mode: :read,
           position: 0,
           size: 0,
           path: path,
           bucket: bucket,
           stream: []
         }}
    end
  end

  def handle_continue(:open, %{path: path, bucket: bucket, mode: :write}) do
    # Initialize multipart upload
    key = path |> to_string()
    req = ExAws.S3.initiate_multipart_upload(bucket, key)

    case ExAws.request(req) do
      {:ok, %{body: %{upload_id: upload_id}}} ->
        {:noreply,
         %{
           mode: :write,
           path: path,
           bucket: bucket,
           upload_id: upload_id,
           part: 1,
           parts: []
         }}

      {:error, err} ->
        Logger.error("Failed to initiate multipart upload: #{inspect(err)}")
        {:stop, {:error, :einval}, %{path: path, bucket: bucket, mode: :write}}
    end
  end

  @impl GenServer
  def handle_call({:position, {:bof, _offset}}, _from, %{mode: :read, path: path, bucket: bucket} = state) do
    {:reply, {:ok, 0},
     Map.merge(state, %{position: 0, stream: Operations.read_stream(path, bucket)})}
  end

  def handle_call({:position, {:bof, _offset}}, _from, %{mode: :write} = state) do
    {:reply, {:ok, 0}, state}
  end

  def handle_call({:position, offset}, _from, state) do
    {:reply, {:ok, offset}, state}
  end

  def handle_call({:read, _length}, _from, %{size: size, position: pos} = state)
      when pos >= size do
    {:reply, :eof, state}
  end

  def handle_call(
        {:read, length},
        _from,
        %{stream: stream, size: size, position: pos} = state
      ) do
    # Read up to the remaining bytes in the file
    bytes_to_read = min(length, size - pos)
    ret = Enum.take(stream, bytes_to_read) |> Enum.join()

    {:reply, {:ok, ret}, %{state | position: pos + byte_size(ret), stream: stream}}
  end

  def handle_call(
        {:write, data},
        _from,
        %{path: path, part: part, bucket: bucket, upload_id: upload_id, parts: parts} = state
      ) do
    key = path |> to_string()
    req = ExAws.S3.upload_part(bucket, key, upload_id, part, data)

    case ExAws.request(req) do
      {:ok, %{headers: headers}} ->
        # Extract ETag from response headers
        etag =
          headers
          |> List.keyfind("ETag", 0)
          |> case do
            {_, etag} -> String.trim(etag, "\"")
            nil -> ""
          end

        new_parts = parts ++ [{part, etag}]
        {:reply, :ok, %{state | part: part + 1, parts: new_parts}}

      {:error, err} ->
        Logger.error("Write failed: #{inspect(err)}")
        {:reply, {:error, :einval}, state}
    end
  end

  @impl GenServer
  def handle_info(
        {:file_request, _, _ref, :close},
        %{mode: :write, path: path, bucket: bucket, upload_id: upload_id, parts: parts} = state
      ) do
    key = path |> to_string()
    req = ExAws.S3.complete_multipart_upload(bucket, key, upload_id, parts)

    case ExAws.request(req) do
      {:ok, _} ->
        {:stop, :normal, state}

      {:error, err} ->
        Logger.error("Failed to complete multipart upload: #{inspect(err)}")
        ExAws.S3.abort_multipart_upload(bucket, key, upload_id) |> ExAws.request()
        {:stop, {:error, :einval}, state}
    end
  end

  def handle_info({:file_request, _, _ref, :close}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{mode: :write, path: path, bucket: bucket, upload_id: upload_id, parts: parts}) do
    key = path |> to_string()
    req = ExAws.S3.complete_multipart_upload(bucket, key, upload_id, parts)

    case ExAws.request(req) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.warning("Failed to complete multipart upload during terminate: #{inspect(err)}")
        ExAws.S3.abort_multipart_upload(bucket, key, upload_id) |> ExAws.request()
        :ok
    end
  end

  def terminate(_reason, _state) do
    :ok
  end
end
