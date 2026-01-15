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
    {GenServer.stop(io_device), state}
  end

  @impl true
  def delete(path, %{bucket: bucket} = state) do
    {Operations.delete(path, bucket), state}
  end

  @impl true
  def del_dir(path, %{bucket: bucket} = state) do
    {Operations.del_dir(path, bucket), state}
  end

  @impl true
  def get_cwd(%{cwd: cwd} = state) do
    {{:ok, cwd}, state}
  end

  def get_cwd(state) do
    {{:ok, ~c"/"}, Map.merge(state, %{cwd: ~c"/"})}
  end

  @impl true
  def is_dir(path, %{bucket: bucket} = state) do
    case Operations.read_link_info(path, bucket) do
      {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} ->
        {true, state}

      {:ok, {:file_info, _, :regular, _, _, _, _, _, _, _, _, _, _, _}} ->
        {false, state}

      {:error, _} ->
        {false, state}
    end
  end

  @impl true
  def list_dir(abs_path, %{bucket: bucket} = state) do
    dir_listing = Operations.list_dir(abs_path, bucket)
    {{:ok, dir_listing}, state}
  end

  @impl true
  def make_dir(path, %{bucket: bucket} = state) do
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
  def read_link_info(path, state) when path in [~c"/.", ~c"..", ~c"."] do
    {{:ok, Operations.fake_directory_info()}, state}
  end

  def read_link_info(path, %{bucket: bucket} = state) do
    {Operations.read_link_info(path, bucket), state}
  end

  @impl true
  def open(path, [:binary, :read], %{bucket: bucket} = state) do
    {IODevice.start(%{path: path, bucket: bucket, mode: :read}), state}
  end

  def open(path, [:binary, :write], %{bucket: bucket} = state) do
    {IODevice.start(%{path: path, bucket: bucket, mode: :write}), state}
  end

  def open(path, modes, %{bucket: bucket} = state) do
    cond do
      :write in modes ->
        {IODevice.start(%{path: path, bucket: bucket, mode: :write}), state}

      :read in modes ->
        {IODevice.start(%{path: path, bucket: bucket, mode: :read}), state}

      true ->
        {{:error, :einval}, state}
    end
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
  def read_file_info(path, %{bucket: bucket} = state) do
    {Operations.read_link_info(path, bucket), state}
  end

  @impl true
  def write_file_info(path, info, state) do
    {:file.write_file_info(path, info), state}
  end

  @impl true
  def rename(src, dst, %{bucket: bucket} = state) do
    {Operations.rename(src, dst, bucket), state}
  end

  @impl true
  def write(io_device, data, state) do
    {GenServer.call(io_device, {:write, data}), state}
  end
end
