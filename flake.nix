{
  description = "Barnyard";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    ponies-nix.url = "github:ducharmemp/ponies-nix";
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem =
        { config, pkgs, inputs', ... }:
        let
          ponyPackages = with inputs'.ponies-nix.packages; [
            pony-lsp
            pony-lint
            ponyc
            corral
            pony-doc
          ];
          # Needed everywhere
          basePackages = with pkgs; [
            llvm
            glibc
            just
            openssl_3
          ];
          # Needed only on local machines
          developerPackages = with pkgs; [
            podman
            podman-compose
            postgresql
            pgbouncer
            pgdog
            perf
            inferno
            bpftrace
          ];
        in
        {
          devShells.ci = pkgs.mkShell {
            buildInputs = ponyPackages ++ basePackages;
          };

          devShells.default = (pkgs.mkShell.override { stdenv = pkgs.llvmPackages.libcxxStdenv; }) {
            buildInputs = ponyPackages ++ basePackages ++ developerPackages;
          };

          formatter = pkgs.nixfmt-rfc-style;
        };
    };
}
