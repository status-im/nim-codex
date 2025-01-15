## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/poseidon2
import pkg/questionable/results
import pkg/libp2p/multihash
import pkg/stew/byteutils

import ../merkletree

func spongeDigest*(
    _: type Poseidon2Hash, bytes: openArray[byte], rate: static int = 2
): ?!Poseidon2Hash =
  ## Hashes chunks of data with a sponge of rate 1 or 2.
  ##

  success Sponge.digest(bytes, rate)

func spongeDigest*(
    _: type Poseidon2Hash, bytes: openArray[Bn254Fr], rate: static int = 2
): ?!Poseidon2Hash =
  ## Hashes chunks of elements with a sponge of rate 1 or 2.
  ##

  success Sponge.digest(bytes, rate)

func digestTree*(
    _: type Poseidon2Tree, bytes: openArray[byte], chunkSize: int
): ?!Poseidon2Tree =
  ## Hashes chunks of data with a sponge of rate 2, and combines the
  ## resulting chunk hashes in a merkle root.
  ##

  # doAssert not(rate == 1 or rate == 2), "rate can only be 1 or 2"

  if not chunkSize > 0:
    return failure("chunkSize must be greater than 0")

  var index = 0
  var leaves: seq[Poseidon2Hash]
  while index < bytes.len:
    let start = index
    let finish = min(index + chunkSize, bytes.len)
    let digest = ?Poseidon2Hash.spongeDigest(bytes.toOpenArray(start, finish - 1), 2)
    leaves.add(digest)
    index += chunkSize
  return Poseidon2Tree.init(leaves)

func digest*(
    _: type Poseidon2Tree, bytes: openArray[byte], chunkSize: int
): ?!Poseidon2Hash =
  ## Hashes chunks of data with a sponge of rate 2, and combines the
  ## resulting chunk hashes in a merkle root.
  ##

  (?Poseidon2Tree.digestTree(bytes, chunkSize)).root

func digestMhash*(
    _: type Poseidon2Tree, bytes: openArray[byte], chunkSize: int
): ?!MultiHash =
  ## Hashes chunks of data with a sponge of rate 2 and
  ## returns the multihash of the root
  ##

  let hash = ?Poseidon2Tree.digest(bytes, chunkSize)

  ?MultiHash.init(Pos2Bn128MrklCodec, hash).mapFailure
