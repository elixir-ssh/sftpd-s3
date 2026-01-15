defmodule Sftpd.Test.SSHKeysTest do
  use ExUnit.Case, async: true

  alias Sftpd.Test.SSHKeys

  describe "generate_system_dir/0" do
    test "creates a temporary directory" do
      dir = SSHKeys.generate_system_dir()

      assert File.dir?(dir)
      assert String.starts_with?(dir, System.tmp_dir!())
    end

    test "generates RSA host key" do
      dir = SSHKeys.generate_system_dir()
      key_path = Path.join(dir, "ssh_host_rsa_key")

      assert File.exists?(key_path)
      content = File.read!(key_path)
      assert content =~ "RSA PRIVATE KEY"
    end

    test "generates ED25519 host key" do
      dir = SSHKeys.generate_system_dir()
      key_path = Path.join(dir, "ssh_host_ed25519_key")

      assert File.exists?(key_path)
      content = File.read!(key_path)
      assert content =~ "OPENSSH PRIVATE KEY"
    end

    test "generates ECDSA host key" do
      dir = SSHKeys.generate_system_dir()
      key_path = Path.join(dir, "ssh_host_ecdsa_key")

      assert File.exists?(key_path)
      content = File.read!(key_path)
      assert content =~ "EC PRIVATE KEY"
    end

    test "sets correct permissions on key files" do
      dir = SSHKeys.generate_system_dir()

      for key_file <- ["ssh_host_rsa_key", "ssh_host_ed25519_key", "ssh_host_ecdsa_key"] do
        key_path = Path.join(dir, key_file)
        {:ok, %{mode: mode}} = File.stat(key_path)
        # Check that only owner has read/write (0o600)
        assert Bitwise.band(mode, 0o777) == 0o600
      end
    end

    test "cleans up directory when calling process exits" do
      test_pid = self()

      # Spawn a process that creates keys and sends back the dir path
      spawn(fn ->
        dir = SSHKeys.generate_system_dir()
        send(test_pid, {:dir, dir})
        # Exit immediately
      end)

      # Get the directory path
      assert_receive {:dir, dir}, 1000

      # Wait for cleanup to happen
      Process.sleep(100)

      # Directory should be cleaned up
      refute File.exists?(dir)
    end

    test "generates valid RSA key that can be parsed" do
      dir = SSHKeys.generate_system_dir()
      key_path = Path.join(dir, "ssh_host_rsa_key")
      pem = File.read!(key_path)

      [entry] = :public_key.pem_decode(pem)
      key = :public_key.pem_entry_decode(entry)

      # RSA key should be a tuple starting with :RSAPrivateKey
      assert elem(key, 0) == :RSAPrivateKey
    end

    test "generates valid ECDSA key that can be parsed" do
      dir = SSHKeys.generate_system_dir()
      key_path = Path.join(dir, "ssh_host_ecdsa_key")
      pem = File.read!(key_path)

      [entry] = :public_key.pem_decode(pem)
      key = :public_key.pem_entry_decode(entry)

      # ECDSA key should be a tuple starting with :ECPrivateKey
      assert elem(key, 0) == :ECPrivateKey
    end
  end
end
