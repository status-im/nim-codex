{
  description = "Codex build flake";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
      pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in rec {
      devShells = forAllSystems (system: let
        pkgs = pkgsFor.${system};
        inherit (pkgs) lib stdenv mkShell;
      in {
        default = mkShell.override { stdenv = pkgs.gcc11Stdenv; } {
          buildInputs = with pkgs; [
              # General
              git pkg-config openssl lsb-release
              # Build
              rustc cargo nimble gcc11 cmake nim-unwrapped-1
              # Libraries
              gmp llvmPackages.openmp
              # Tests
              nodejs_18
          ];
        };
      });
    };
}