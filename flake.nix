{
  description = "Development environment for sftp-s3";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        lib = pkgs.lib;
        erlang = pkgs.erlang.override {
          version = "28.0";
          src = pkgs.fetchurl {
            url = "https://github.com/erlang/otp/releases/download/OTP-28.0/otp_src_28.0.tar.gz";
            sha256 = "sha256-tmwsxPoshyEbZo5EhtTz5bG2cFaYhz6j5tmFCAGsmS0=";
          };
        };
        beamPackages = pkgs.beam.packagesWith erlang;
        elixir = beamPackages.elixir.override {
          erlang = erlang;
          version = "1.18.1";
          src = pkgs.fetchurl {
            url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v1.18.1.tar.gz";
            sha256 = "sha256-QjWmPGFcfHh9haUWfbKKWOyfWlefmz/YU/xvTYhsIJ4=";
          };
        };
      in {
        devShell = pkgs.mkShell {
          nativeBuildInputs =
            [
              erlang
              elixir
              beamPackages.ex_doc
              beamPackages.hex
              beamPackages.rebar
              beamPackages.rebar3
              beamPackages.rebar3-nix
              pkgs.tailwindcss
              pkgs.git
              pkgs.gh
              pkgs.nodePackages.cspell
              pkgs.alejandra
              pkgs.nil
            ]
            ++ lib.optional pkgs.stdenv.isLinux pkgs.libnotify
            ++ lib.optional pkgs.stdenv.isLinux pkgs.inotify-tools
            ++ lib.optional pkgs.stdenv.isDarwin pkgs.terminal-notifier
            ++ lib.optionals pkgs.stdenv.isDarwin (with pkgs.darwin.apple_sdk.frameworks; [CoreFoundation CoreServices]);
          shellHook = ''
            gh auth switch --user mjc
            export ERL_AFLAGS="-kernel shell_history enabled"
          '';
        };
      }
    );
}
