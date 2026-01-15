defmodule Sftpd.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/mjc/sftpd"

  def project do
    [
      app: :sftpd,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: "Pluggable SFTP server with support for S3 and custom backends",
      package: package(),

      # Docs
      name: "Sftpd",
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh]
    ]
  end

  defp deps do
    [
      # S3 backend dependencies (optional for users who only need S3)
      {:ex_aws, "~> 2.0"},
      {:ex_aws_s3, "~> 2.0"},
      {:hackney, "~> 1.9"},
      {:sweet_xml, "~> 0.6"},
      {:jason, "~> 1.3"},
      {:configparser_ex, "~> 4.0"},

      # Dev/test dependencies
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp aliases do
    [
      # Use --no-start to prevent automatic application startup. Applications are
      # started explicitly in test_helper.exs to control the startup order and
      # avoid issues with SSH daemon initialization during test discovery.
      test: ["test --no-start"]
    ]
  end

  defp package do
    [
      maintainers: ["Michael Christensen"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Sftpd",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [Sftpd, Sftpd.Backend],
        Backends: [Sftpd.Backends.S3, Sftpd.Backends.Memory],
        Internal: [Sftpd.FileHandler, Sftpd.IODevice],
        Legacy: [SftpdS3]
      ]
    ]
  end
end
