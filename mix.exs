defmodule SftpdS3.MixProject do
  use Mix.Project

  def project do
    [
      app: :sftpd_s3,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      preferred_cli_env: [
        vcr: :test,
        "vcr.delete": :test,
        "vcr.check": :test,
        "vcr.show": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :hackney]
    ]
  end

  # most of these should be test only before release
  defp deps do
    [
      {:configparser_ex, "~> 4.0"},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_aws_s3, "~> 2.0"},
      {:ex_aws, "~> 2.0"},
      {:hackney, "~> 1.9"},
      {:jason, "~> 1.3"},
      {:sweet_xml, "~> 0.6.0"},
      {:timex, "~> 3.7.0"}
    ]
  end
end
