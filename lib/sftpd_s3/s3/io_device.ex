defmodule SftpdS3.S3.IODevice do
  use GenServer

  alias SftpdS3.S3.Operations

  require Logger

  @spec start_link(map) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  @spec init(%{:bucket => String.t(), :path => charlist()}) ::
          {:ok, %{bucket: any, path: any}, {:continue, :open}}
  def init(%{path: path, bucket: bucket}) do
    {:ok, %{path: path, bucket: bucket}, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, %{path: path, bucket: bucket}) do
    {:ok, fi} = Operations.read_link_info(path, bucket)
    size = fi |> elem(1)

    {:noreply,
     %{
       position: 0,
       size: size,
       path: path,
       stream: Operations.read_stream(path |> to_string(), bucket)
     }}
  end

  @impl GenServer
  def handle_call({:position, {:bof, _offset}}, _from, %{path: path, bucket: bucket} = state) do
    dbg("Asked to rewind stream to beginning. Reopening instead.")

    {:reply, {:ok, 0},
     Map.merge(state, %{position: 0, stream: Operations.read_stream(path, bucket)})}
  end

  def handle_call({:position, offset}, _from, state) do
    dbg(offset, label: "position")
    {:reply, {:ok, offset}, state}
  end

  def handle_call({:read, length}, _from, %{size: size, position: pos} = state)
      when pos + length > size do
    dbg("Asked to read past end of file: #{pos} + #{length} > #{size}")
    {:reply, {:error, :badarg}, state}
  end

  def handle_call({:read, _length}, _from, %{size: size, position: pos} = state)
      when pos >= size do
    dbg("EOF - pos: #{pos}, size: #{size}")
    {:reply, {:eof, 0}, state}
  end

  def handle_call(
        {:read, length},
        _from,
        %{stream: stream, position: pos} = state
      ) do
    ret = Enum.take(stream, length) |> Enum.join()

    {:reply, {:ok, ret}, %{state | position: pos + byte_size(ret), stream: stream}}
  end

  def handle_call({:write, data}, from, %{path: path, part: part, bucket: bucket} = state) do
    resp = Operations.write(path, to_string(from), part, data, bucket)
    {:reply, resp, %{state | part: part + 1}}
  end

  @impl GenServer
  def handle_info({:file_request, _, ref, :close}, state) do
    dbg(ref, label: "close")
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    dbg(message, label: "handle_info")
    {:noreply, state}
  end
end
