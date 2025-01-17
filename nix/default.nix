{
  pkgs ? import <nixpkgs> { },
  src ? ../.,
  targets ? ["all"],
  # Options: 0,1,2
  verbosity ? 1,
  commit ? builtins.substring 0 7 (src.rev or "dirty"),
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
    "x86_64-darwin" "aarch64-darwin"
  ],
  # Perform 2-stage bootstrap instead of 3-stage to save time.
  quickAndDirty ? true,
  circomCompatPkg ? (
    builtins.getFlake "github:codex-storage/circom-compat-ffi"
  ).packages.${builtins.currentSystem}.default
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;

  revision = lib.substring 0 8 (src.rev or "dirty");

  tools = callPackage ./tools.nix {};
in pkgs.gcc13Stdenv.mkDerivation rec {

  pname = "codex";

  version = "${tools.findKeyValue "version = \"([0-9]+\.[0-9]+\.[0-9]+)\"" ../codex.nimble}-${revision}";

  inherit src;

  # Dependencies that should exist in the runtime environment.
  buildInputs = with pkgs; [
    openssl
    gmp
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
    # Fix for the nim-circom-compat-ffi package that is built with cargo.
    fakeCargo = writeScriptBin "cargo" "echo ${version}";
  in
    with pkgs; [
      cmake
      which
      lsb-release
      circomCompatPkg
      fakeGit
      fakeCargo
  ];

  # Disable CPU optmizations that make binary not portable.
  NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}";
  # Avoid Nim cache permission errors.
  XDG_CACHE_HOME = "/tmp";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "QUICK_AND_DIRTY_COMPILER=${if quickAndDirty then "1" else "0"}"
    "QUICK_AND_DIRTY_NIMBLE=${if quickAndDirty then "1" else "0"}"
  ];

  configurePhase = ''
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
  '';

  preBuild = ''
    pushd vendor/nimbus-build-system/vendor/Nim
    mkdir dist
    cp -r ${callPackage ./nimble.nix {}}    dist/nimble
    cp -r ${callPackage ./checksums.nix {}} dist/checksums
    cp -r ${callPackage ./csources.nix {}}  csources_v2
    chmod 777 -R dist/nimble csources_v2
    popd
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp build/codex $out/bin/
  '';

  meta = with pkgs.lib; {
    description = "Nim Codex storage system";
    homepage = "https://github.com/codex-storage/nim-codex";
    license = licenses.mit;
    platforms = stableSystems;
  };
}