defmodule Sftpd.FileHandler do
  @moduledoc """
  Generic file handler for Erlang's ssh_sftpd server module.

  This module implements the `:ssh_sftpd_file_api` behaviour and delegates
  all storage operations to the configured backend.

  ## Usage

  This module is used internally by `Sftpd.start_server/1`. You typically
  don't need to use it directly unless you're customizing the SSH daemon setup.

      :ssh_sftpd.subsystem_spec(
        file_handler: {Sftpd.FileHandler, %{backend: MyBackend, backend_state: state}}
      )
  """

  @behaviour :ssh_sftpd_file_api

  alias Sftpd.{Backend, IODevice}

  @impl true
  def close(io_device, state) do
    {GenServer.stop(io_device), state}
  end

  @impl true
  def delete(path, %{backend: backend, backend_state: backend_state} = state) do
    {Backend.call(backend, :delete, [path, backend_state]), state}
  end

  @impl true
  def del_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    {Backend.call(backend, :del_dir, [path, backend_state]), state}
  end

  @impl true
  def get_cwd(%{cwd: cwd} = state) do
    {{:ok, cwd}, state}
  end

  def get_cwd(state) do
    {{:ok, ~c"/"}, Map.put(state, :cwd, ~c"/")}
  end

  @impl true
  def is_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    case Backend.call(backend, :file_info, [path, backend_state]) do
      {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} ->
        {true, state}

      {:ok, {:file_info, _, :regular, _, _, _, _, _, _, _, _, _, _, _}} ->
        {false, state}

      {:error, _} ->
        {false, state}
    end
  end

  @impl true
  def list_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    {Backend.call(backend, :list_dir, [path, backend_state]), state}
  end

  @impl true
  def make_dir(path, %{backend: backend, backend_state: backend_state} = state) do
    {Backend.call(backend, :make_dir, [path, backend_state]), state}
  end

  @impl true
  def make_symlink(_src, _dst, state) do
    {{:error, :enotsup}, state}
  end

  @impl true
  def read_link(_path, state) do
    {{:error, :enotsup}, state}
  end

  @impl true
  def read_link_info(path, state) when path in [~c"/", ~c"/.", ~c"/..", ~c"..", ~c"."] do
    {{:ok, Backend.directory_info()}, state}
  end

  def read_link_info(path, %{backend: backend, backend_state: backend_state} = state) do
    path_str = to_string(path)

    if String.ends_with?(path_str, "/.") or String.ends_with?(path_str, "/..") do
      {{:ok, Backend.directory_info()}, state}
    else
      {Backend.call(backend, :file_info, [path, backend_state]), state}
    end
  end

  @impl true
  def open(path, modes, %{backend: backend, backend_state: backend_state} = state) do
    mode =
      cond do
        :write in modes -> :write
        :read in modes -> :read
        true -> :read
      end

    result =
      IODevice.start(%{
        path: path,
        mode: mode,
        backend: backend,
        backend_state: backend_state
      })

    {result, state}
  end

  @impl true
  def position(io_device, offset, state) do
    {GenServer.call(io_device, {:position, offset}), state}
  end

  @impl true
  def read(io_device, len, state) do
    {GenServer.call(io_device, {:read, len}), state}
  end

  @impl true
  def read_file_info(path, state) do
    read_link_info(path, state)
  end

  @impl true
  def write_file_info(_path, _info, state) do
    {:ok, state}
  end

  @impl true
  def rename(src, dst, %{backend: backend, backend_state: backend_state} = state) do
    {Backend.call(backend, :rename, [src, dst, backend_state]), state}
  end

  @impl true
  def write(io_device, data, state) do
    {GenServer.call(io_device, {:write, data}), state}
  end
end
