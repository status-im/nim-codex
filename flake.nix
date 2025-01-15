{
  description = "Nim Codex build flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    circom-compat = {
      url = "github:codex-storage/circom-compat-ffi";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, circom-compat}:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs stableSystems (system: f system);
      pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in rec {
      packages = forAllSystems (system: let
        circomCompatPkg = circom-compat.packages.${system}.default;
        buildTarget = pkgsFor.${system}.callPackage ./nix/default.nix rec {
          inherit stableSystems circomCompatPkg;
          src = self;
        };
        build = targets: buildTarget.override { inherit targets; };
      in rec {
        nim-codex   = build ["all"];
        default = nim-codex;
      });

      nixosModules.nim-codex = { config, lib, pkgs, ... }: import ./nix/service.nix {
        inherit config lib pkgs self;
        circomCompatPkg = circom-compat.packages.${pkgs.system}.default;
      };

      devShells = forAllSystems (system: let
        pkgs = pkgsFor.${system};
      in {
        default = pkgs.mkShell {
          inputsFrom = [
            packages.${system}.nim-codex
            circom-compat.packages.${system}.default
          ];
          # Not using buildInputs to override fakeGit and fakeCargo.
          nativeBuildInputs = with pkgs; [ git cargo nodejs_18 ];
        };
      });

      checks = forAllSystems (system: let
        pkgs = pkgsFor.${system};
      in {
        nim-codex-test = pkgs.nixosTest {
          name = "nim-codex-test";
          nodes = {
            server = { config, pkgs, ... }: {
              imports = [ self.nixosModules.nim-codex ];
              services.nim-codex.enable = true;
              services.nim-codex.settings = {
                data-dir = "/var/lib/nim-codex-test";
              };
              systemd.services.nim-codex.serviceConfig.StateDirectory = "nim-codex-test";
            };
          };
          testScript = ''
            print("Starting test: nim-codex-test")
            machine.start()
            machine.wait_for_unit("nim-codex.service")
            machine.succeed("test -d /var/lib/nim-codex-test")
            machine.wait_until_succeeds("journalctl -u nim-codex.service | grep 'Started codex node'", 10)
          '';
        };
      });
    };
}