# Usage

## Shell

A development shell can be started using:
```sh
nix develop '.?submodules=1#'
```

## Building

To build a Codex you can use:
```sh
nix build '.?submodules=1#default'
```
The `?submodules=1` part should eventually not be necessary.
For more details see:
https://github.com/NixOS/nix/issues/4423

It can be also done without even cloning the repo:
```sh
nix build 'git+https://github.com/codex-storage/nim-codex?submodules=1#'
```

## Running

```sh
nix run 'git+https://github.com/codex-storage/nim-codex?submodules=1#''
```

## Testing

```sh
nix flake check ".?submodules=1#"
```

## Running Nim-Codex as a service on NixOS

Include nim-codex flake in your flake inputs:
```nix
inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nim-codex-flake.url = "git+https://github.com/codex-storage/nim-codex?submodules=1#";
};
```

To configure the service, you can use the following example:
```nix
services.nim-codex = {
   enable = true;
   settings = {
       data-dir = "/var/lib/codex-test";
   };
};
```
The settings attribute set corresponds directly to the layout of the TOML configuration file 
used by nim-codex. Each option follows the same naming convention as the CLI flags, but 
with the -- prefix removed. For more details on the TOML file structure and options, 
refer to the official documentation: [nim-codex configuration file](https://docs.codex.storage/learn/run#configuration-file).