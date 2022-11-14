defmodule SftpdS3.S3.FileHandler do
  @moduledoc """
    Provides file handler for erlang's ssh_sftpd server module
  """

  @behaviour :ssh_sftpd_file_api

  alias SftpdS3.S3.{IODevice, Operations}

  require Logger

  @impl true
  @spec close(any, any) :: {:ok, any}
  def close(io_device, state) do
    dbg(io_device, label: "close")
    {GenServer.stop(io_device), state}
  end

  @impl true
  def delete(path, state) do
    dbg(path, label: "delete")
    {{:error, :eperm}, state}
  end

  @impl true
  def del_dir(path, %{bucket: bucket} = state) do
    dbg(path, label: "del_dir")
    {Operations.del_dir(path, bucket), state}
  end

  @impl true
  def get_cwd(%{cwd: cwd} = state) do
    dbg(state, label: "get_cwd")
    {{:ok, cwd}, state}
  end

  def get_cwd(state) do
    dbg(state, label: "get_cwd")
    {{:ok, '/'}, Map.merge(state, %{cwd: '/'})}
  end

  @impl true
  def is_dir(path,  %{bucket: bucket} = state) do
    dbg(path, label: "is_dir")

    case Operations.read_link_info(path, bucket) do
      {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} ->
        {true, state}

      {:ok, {:file_info, _, :regular, _, _, _, _, _, _, _, _, _, _, _}} ->
        {false, state}
    end
  end

  @impl true
  def list_dir(abs_path,  %{bucket: bucket} = state) do
    dbg(abs_path, label: "list_dir")
    dir_listing = Operations.list_dir(abs_path, bucket)
    {{:ok, dir_listing}, state}
  end

  @impl true

  def make_dir(path,  %{bucket: bucket} = state) do
    dbg(path, label: "make_dir")
    {Operations.make_dir(path, bucket), state}
  end

  @impl true

  def make_symlink(src, dst, state) do
    Logger.debug("make_symlink: src: #{src}, dst: #{dst}")
    {{:error, :eperm}, state}
  end

  @impl true

  def read_link(path, state) do
    Logger.debug("Symlinks not supported. read_link: #{path}")

    {{:error, :einval}, state}
  end

  @impl true
  def read_link_info(path, state) when path in ['/.', '..', '.'] do
    dbg(path, label: "read_link_info")
    {{:ok, Operations.fake_directory_info()}, state}
  end

  def read_link_info(path,  %{bucket: bucket} = state) do
    dbg(path, label: "read_link_info from S3")
    {Operations.read_link_info(path, bucket),  state}
  end

  @impl true
  def open(path, [:binary, :read], %{bucket: bucket} = state) do
    dbg(path, label: "open for read")
    {IODevice.start_link(%{path: path, bucket: bucket}), state}
  end

  def open(path, [:binary, :write], %{bucket: bucket} = state) do
    dbg(path, label: "open for write")
    {IODevice.start_link(%{path: path, bucket: bucket}), state}
  end

  def open(path, modes, state) do
    dbg(path, label: "open")
    dbg(modes, label: "open")

    {{:error, :einval}, state}
  end

  @impl true
  def position(io_device, offset, state) do
    dbg(offset, label: "position")

    {GenServer.call(io_device, {:position, offset}), state}
  end

  @impl true
  def read(io_device, len, state) do
    dbg(len, label: "read")

    {GenServer.call(io_device, {:read, len}), state}
  end

  @impl true
  def read_file_info(path,  %{bucket: bucket} = state) do
    dbg(path, label: "read_file_info")
    {Operations.read_link_info(path, bucket), state}
  end

  @impl true
  def write_file_info(path, info, state) do
    dbg(path, label: "write_file_info")
    {:file.write_file_info(path, info), state}
  end

  @impl true
  def rename(src, dst, state) do
    dbg({src, dst}, label: "rename")
    {:file.rename(src, dst), state}
  end

  @impl true
  def write(io_device, data, state) do
    dbg("write")

    {GenServer.call(io_device, {:write, data}), state}
  end
end
