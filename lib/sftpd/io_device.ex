defmodule Sftpd.IODevice do
  @moduledoc """
  GenServer that manages file handles for SFTP read/write operations.

  This module buffers reads and writes, delegating actual storage operations
  to the configured backend.
  """

  use GenServer

  require Logger

  @doc """
  Start an IODevice process (not linked to caller).

  Uses GenServer.start/2 instead of start_link to avoid crashing the
  SFTP channel when the IODevice terminates normally after file close.
  """
  @spec start(map()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl GenServer
  def init(%{path: path, mode: mode, backend: backend, backend_state: backend_state}) do
    {:ok, %{path: path, mode: mode, backend: backend, backend_state: backend_state},
     {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(
        :open,
        %{path: path, mode: :read, backend: backend, backend_state: backend_state} = state
      ) do
    case backend.read_file(path, backend_state) do
      {:ok, content} ->
        {:noreply, Map.merge(state, %{content: content, size: byte_size(content), position: 0})}

      {:error, _reason} ->
        {:noreply, Map.merge(state, %{content: <<>>, size: 0, position: 0})}
    end
  end

  def handle_continue(:open, %{mode: :write} = state) do
    {:noreply, Map.put(state, :buffer, <<>>)}
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

  defp upload_buffer(%{
         path: path,
         buffer: buffer,
         backend: backend,
         backend_state: backend_state
       }) do
    case backend.write_file(path, buffer, backend_state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to write file: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
