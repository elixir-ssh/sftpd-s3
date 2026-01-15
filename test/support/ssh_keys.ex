defmodule Sftpd.Test.SSHKeys do
  @moduledoc """
  Generates SSH host keys dynamically for testing.

  Creates a temporary directory with SSH host keys that can be used
  as the system_dir for SFTP server tests.
  """

  @doc """
  Generate SSH host keys in a temporary directory.

  Returns the path to the directory containing the generated keys.
  The directory and keys will be automatically cleaned up when the
  test process exits.

  ## Example

      setup do
        system_dir = Sftpd.Test.SSHKeys.generate_system_dir()
        %{system_dir: system_dir}
      end
  """
  @spec generate_system_dir() :: String.t()
  def generate_system_dir do
    dir = create_temp_dir()
    generate_host_keys(dir)
    dir
  end

  defp create_temp_dir do
    timestamp = System.system_time(:millisecond)
    random = :rand.uniform(1_000_000)
    dir = Path.join(System.tmp_dir!(), "sftpd_test_keys_#{timestamp}_#{random}")
    File.mkdir_p!(dir)

    # Clean up when calling process exits
    caller = self()

    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        {:DOWN, ^ref, :process, _, _} ->
          File.rm_rf!(dir)
      end
    end)

    dir
  end

  defp generate_host_keys(dir) do
    # Generate RSA key (most widely compatible)
    generate_rsa_key(dir)

    # Generate ED25519 key (modern, fast)
    generate_ed25519_key(dir)

    # Generate ECDSA key
    generate_ecdsa_key(dir)
  end

  defp generate_rsa_key(dir) do
    # Generate 2048-bit RSA key
    rsa_key = :public_key.generate_key({:rsa, 2048, 65537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)])
    File.write!(Path.join(dir, "ssh_host_rsa_key"), pem)
    File.chmod!(Path.join(dir, "ssh_host_rsa_key"), 0o600)
  end

  defp generate_ed25519_key(dir) do
    # Generate ED25519 key pair
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    # Write in OpenSSH format
    write_openssh_ed25519_key(dir, pub, priv)
  end

  defp generate_ecdsa_key(dir) do
    # Generate ECDSA key on secp256r1 curve
    ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])
    File.write!(Path.join(dir, "ssh_host_ecdsa_key"), pem)
    File.chmod!(Path.join(dir, "ssh_host_ecdsa_key"), 0o600)
  end

  defp write_openssh_ed25519_key(dir, pub, priv) do
    # OpenSSH uses a custom format for ED25519 keys
    # Build the key blob
    key_type = "ssh-ed25519"
    check_int = :rand.uniform(0xFFFFFFFF)

    # Public key blob
    pub_blob = encode_string(key_type) <> encode_string(pub)

    # Private key blob (includes public key)
    priv_blob =
      <<check_int::32, check_int::32>> <>
        encode_string(key_type) <>
        encode_string(pub) <>
        encode_string(priv <> pub) <>
        encode_string("")

    # Pad to block size (8 bytes for openssh)
    padding_len = 8 - rem(byte_size(priv_blob), 8)
    padding = for i <- 1..padding_len, into: <<>>, do: <<i::8>>
    priv_blob = priv_blob <> padding

    # Build the full key file
    cipher = "none"
    kdf = "none"
    kdf_options = <<>>
    num_keys = 1

    encoded =
      encode_string(cipher) <>
        encode_string(kdf) <>
        encode_string(kdf_options) <>
        <<num_keys::32>> <>
        encode_string(pub_blob) <>
        encode_string(priv_blob)

    content =
      "-----BEGIN OPENSSH PRIVATE KEY-----\n" <>
        (Base.encode64("openssh-key-v1\0" <> encoded) |> chunk_lines(70)) <>
        "\n-----END OPENSSH PRIVATE KEY-----\n"

    File.write!(Path.join(dir, "ssh_host_ed25519_key"), content)
    File.chmod!(Path.join(dir, "ssh_host_ed25519_key"), 0o600)
  end

  defp encode_string(str) when is_binary(str) do
    <<byte_size(str)::32>> <> str
  end

  defp chunk_lines(str, size) do
    str
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
    |> Enum.join("\n")
  end
end
