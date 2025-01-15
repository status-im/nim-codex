## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/libp2p
import pkg/stew/arrayops
import pkg/questionable
import pkg/questionable/results
import pkg/poseidon2
import pkg/poseidon2/io

import ../codextypes
import ../merkletree
import ../errors
import ../utils/digest

func toCid(hash: Poseidon2Hash, mcodec: MultiCodec, cidCodec: MultiCodec): ?!Cid =
  let
    mhash = ?MultiHash.init(mcodec, hash.toBytes).mapFailure
    treeCid = ?Cid.init(CIDv1, cidCodec, mhash).mapFailure
  success treeCid

proc toPoseidon2Hash(
    cid: Cid, mcodec: MultiCodec, cidCodec: MultiCodec
): ?!Poseidon2Hash =
  if cid.cidver != CIDv1:
    return failure("Unexpected CID version")

  if cid.mcodec != cidCodec:
    return failure(
      "Cid is not of expected codec. Was: " & $cid.mcodec & " but expected: " & $cidCodec
    )

  let
    mhash = ?cid.mhash.mapFailure
    bytes: array[32, byte] = array[32, byte].initCopyFrom(mhash.digestBytes())
    hash = ?Poseidon2Hash.fromBytes(bytes).toFailure

  success hash

func toCellCid*(hash: Poseidon2Hash): ?!Cid =
  toCid(hash, Pos2Bn128MrklCodec, CodexSlotCellCodec)

func fromCellCid*(cid: Cid): ?!Poseidon2Hash =
  toPoseidon2Hash(cid, Pos2Bn128MrklCodec, CodexSlotCellCodec)

func toSlotCid*(hash: Poseidon2Hash): ?!Cid =
  toCid(hash, multiCodec("identity"), SlotRootCodec)

func toSlotCids*(slotRoots: openArray[Poseidon2Hash]): ?!seq[Cid] =
  success slotRoots.mapIt(?it.toSlotCid)

func fromSlotCid*(cid: Cid): ?!Poseidon2Hash =
  toPoseidon2Hash(cid, multiCodec("identity"), SlotRootCodec)

func toVerifyCid*(hash: Poseidon2Hash): ?!Cid =
  toCid(hash, multiCodec("identity"), SlotProvingRootCodec)

func fromVerifyCid*(cid: Cid): ?!Poseidon2Hash =
  toPoseidon2Hash(cid, multiCodec("identity"), SlotProvingRootCodec)

func toEncodableProof*(proof: Poseidon2Proof): ?!CodexProof =
  let encodableProof = CodexProof(
    mcodec: multiCodec("identity"),
    index: proof.index,
    nleaves: proof.nleaves,
    path: proof.path.mapIt(@(it.toBytes)),
  )

  success encodableProof

func toVerifiableProof*(proof: CodexProof): ?!Poseidon2Proof =
  let nodes = proof.path.mapIt(?Poseidon2Hash.fromBytes(it.toArray32).toFailure)

  Poseidon2Proof.init(index = proof.index, nleaves = proof.nleaves, nodes = nodes)
