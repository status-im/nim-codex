## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/random
import std/sequtils
import pkg/chronos
import pkg/questionable/results
import pkg/codex/blocktype as bt
import pkg/codex/stores/repostore
import pkg/codex/clock

import ../../asynctest
import ../helpers/mocktimer
import ../helpers/mockrepostore
import ../helpers/mockclock
import ../examples

import codex/namespaces
import codex/stores/keyutils

proc createManifestCid(): ?!Cid =
  let
    length = rand(4096)
    bytes = newSeqWith(length, rand(uint8))
    mcodec = Sha256HashCodec
    codec = ManifestCodec
    version = CIDv1

  let hash = ?MultiHash.digest($mcodec, bytes).mapFailure
  let cid = ?Cid.init(version, codec, hash).mapFailure
  return success cid

checksuite "KeyUtils":
  test "makePrefixKey should create block key":
    let length = 6
    let cid = Cid.example
    let expectedPrefix = ($cid)[^length ..^ 1]
    let expectedPostfix = $cid

    let key = !makePrefixKey(length, cid).option
    let namespaces = key.namespaces

    check:
      namespaces.len == 4
      namespaces[0].value == CodexRepoNamespace
      namespaces[1].value == "blocks"
      namespaces[2].value == expectedPrefix
      namespaces[3].value == expectedPostfix

  test "makePrefixKey should create manifest key":
    let length = 6
    let cid = !createManifestCid().option
    let expectedPrefix = ($cid)[^length ..^ 1]
    let expectedPostfix = $cid

    let key = !makePrefixKey(length, cid).option
    let namespaces = key.namespaces

    check:
      namespaces.len == 4
      namespaces[0].value == CodexRepoNamespace
      namespaces[1].value == "manifests"
      namespaces[2].value == expectedPrefix
      namespaces[3].value == expectedPostfix

  test "createBlockExpirationMetadataKey should create block TTL key":
    let cid = Cid.example

    let key = !createBlockExpirationMetadataKey(cid).option
    let namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == CodexMetaNamespace
      namespaces[1].value == "ttl"
      namespaces[2].value == $cid

  test "createBlockExpirationMetadataQueryKey should create key for all block TTL entries":
    let key = !createBlockExpirationMetadataQueryKey().option
    let namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == CodexMetaNamespace
      namespaces[1].value == "ttl"
      namespaces[2].value == "*"
