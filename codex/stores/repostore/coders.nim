## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

import std/sugar
import pkg/libp2p/cid
import pkg/serde/json
import pkg/stew/byteutils
import pkg/stew/endians2

import ./types
import ../../errors
import ../../merkletree
import ../../utils/json

proc encode*(t: QuotaUsage): seq[byte] =
  t.toJson().toBytes()

proc decode*(T: type QuotaUsage, bytes: seq[byte]): ?!T =
  T.fromJson(bytes)

proc encode*(t: BlockMetadata): seq[byte] =
  t.toJson().toBytes()

proc decode*(T: type BlockMetadata, bytes: seq[byte]): ?!T =
  T.fromJson(bytes)

proc encode*(t: LeafMetadata): seq[byte] =
  t.toJson().toBytes()

proc decode*(T: type LeafMetadata, bytes: seq[byte]): ?!T =
  T.fromJson(bytes)

proc encode*(t: DeleteResult): seq[byte] =
  t.toJson().toBytes()

proc decode*(T: type DeleteResult, bytes: seq[byte]): ?!T =
  T.fromJson(bytes)

proc encode*(t: StoreResult): seq[byte] =
  t.toJson().toBytes()

proc decode*(T: type StoreResult, bytes: seq[byte]): ?!T =
  T.fromJson(bytes)

proc encode*(i: uint64): seq[byte] =
  @(i.toBytesBE)

proc decode*(T: type uint64, bytes: seq[byte]): ?!T =
  if bytes.len >= sizeof(uint64):
    success(uint64.fromBytesBE(bytes))
  else:
    failure("Not enough bytes to decode `uint64`")

proc encode*(i: Natural | enum): seq[byte] =
  cast[uint64](i).encode

proc decode*(T: typedesc[Natural | enum], bytes: seq[byte]): ?!T =
  uint64.decode(bytes).map((ui: uint64) => cast[T](ui))
