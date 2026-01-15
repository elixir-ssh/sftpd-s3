defmodule SftpdS3.S3.IODevice do
  use GenServer

  alias SftpdS3.S3.Operations

  require Logger

  @doc """
  Starts an IODevice process (not linked to caller).

  Uses GenServer.start/2 instead of start_link to avoid crashing the
  SFTP channel when the IODevice terminates normally after file close.
  """
  @spec start(map) :: GenServer.on_start()
  def start(opts) do
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
    # Eagerly load file content into memory for reliable seeking/reading
    content =
      Operations.read_stream(path, bucket)
      |> Enum.join()

    {:noreply,
     %{
       mode: :read,
       position: 0,
       content: content,
       size: byte_size(content),
       path: path,
       bucket: bucket
     }}
  end

  def handle_continue(:open, %{path: path, bucket: bucket, mode: :write}) do
    # Buffer writes in memory, upload on close
    # This avoids S3's 5MB minimum part size requirement for small files
    {:noreply,
     %{
       mode: :write,
       path: path,
       bucket: bucket,
       buffer: <<>>
     }}
  end

  @impl GenServer
  def handle_call({:position, {:bof, offset}}, _from, %{mode: :read} = state) do
    {:reply, {:ok, offset}, %{state | position: offset}}
  end

  def handle_call({:position, {:bof, _offset}}, _from, %{mode: :write} = state) do
    {:reply, {:ok, 0}, state}
  end

  def handle_call({:position, {:cur, offset}}, _from, %{mode: :read, position: pos} = state) do
    new_pos = pos + offset
    {:reply, {:ok, new_pos}, %{state | position: new_pos}}
  end

  def handle_call({:position, offset}, _from, state) when is_integer(offset) do
    {:reply, {:ok, offset}, state}
  end

  def handle_call({:read, _length}, _from, %{size: size, position: pos} = state)
      when pos >= size do
    {:reply, :eof, state}
  end

  def handle_call({:read, length}, _from, %{content: content, size: size, position: pos} = state) do
    bytes_to_read = min(length, size - pos)
    data = binary_part(content, pos, bytes_to_read)
    {:reply, {:ok, data}, %{state | position: pos + bytes_to_read}}
  end

  def handle_call({:write, data}, _from, %{mode: :write, buffer: buffer} = state) do
    {:reply, :ok, %{state | buffer: buffer <> IO.iodata_to_binary(data)}}
  end

  @impl GenServer
  def handle_info({:file_request, _, _ref, :close}, %{mode: :write} = state) do
    upload_buffer(state)
    {:stop, :normal, state}
  end

  def handle_info({:file_request, _, _ref, :close}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{mode: :write, buffer: buffer} = state) when byte_size(buffer) > 0 do
    upload_buffer(state)
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp upload_buffer(%{path: path, bucket: bucket, buffer: buffer}) do
    key = Operations.to_s3_key(path)

    case ExAws.request(ExAws.S3.put_object(bucket, key, buffer)) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.error("Failed to upload file: #{inspect(err)}")
        {:error, :einval}
    end
  end
end
