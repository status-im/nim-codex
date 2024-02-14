version = "0.1.0"
author = "Codex Team"
description = "p2p data durability engine"
license = "MIT"
binDir = "build"
srcDir = "."
installFiles  = @["build.nims"]

requires "nim >= 1.2.0"
requires "asynctest >= 0.5.1 & < 0.6.0"
requires "bearssl >= 0.1.4"
requires "chronicles >= 0.7.2"
requires "chronos >= 2.5.2"
requires "confutils"
requires "ethers >= 0.7.3 & < 0.8.0"
requires "libbacktrace"
requires "libp2p"
requires "metrics"
requires "nimcrypto >= 0.4.1"
requires "nitro >= 0.5.1 & < 0.6.0"
requires "presto"
requires "protobuf_serialization >= 0.2.0 & < 0.3.0"
requires "questionable >= 0.10.13 & < 0.11.0"
requires "secp256k1"
requires "serde >= 1.0.0 & < 2.0.0"
requires "stew"
requires "upraises >= 0.1.0 & < 0.2.0"
requires "toml_serialization"
requires "https://github.com/status-im/lrucache.nim#1.2.2"
requires "leopard >= 0.1.0 & < 0.2.0"
requires "blscurve"
requires "libp2pdht"
requires "eth"
requires "https://github.com/codex-storage/nim-poseidon2.git >= 0.1.0 & < 0.2.0"

include "build.nims"
