{
  description = "Stable";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
        { config, pkgs, ... }:
        let
          # Needed everywhere
          basePackages = with pkgs; [
            ponyc
            pony-corral
            just
            openssl_3
          ];
          # Needed only on local machines
          developerPackages = with pkgs; [
            podman
            podman-compose
            postgresql
          ];
        in
        {
          devShells.ci = pkgs.mkShell {
            buildInputs = basePackages;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath basePackages;
          };

          devShells.default = pkgs.mkShell {
            buildInputs = basePackages ++ developerPackages;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath basePackages;
          };

          formatter = pkgs.nixfmt-rfc-style;
        };
    };
}
