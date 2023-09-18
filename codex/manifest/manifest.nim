## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines all operations on Manifest

import pkg/upraises

push: {.upraises: [].}

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles

import ../errors
import ../utils
import ../units
import ../blocktype
import ./types

export types

type
  Manifest* = ref object of RootObj
    treeCid: Cid           # Cid of the merkle tree
    treeRoot: MultiHash    # Root hash of the merkle tree
    originalBytes: NBytes # Exact size of the original (uploaded) file
    blockSize: NBytes      # Size of each contained block (might not be needed if blocks are len-prefixed)
    version: CidVersion    # Cid version
    hcodec: MultiCodec     # Multihash codec
    codec: MultiCodec      # Data set codec
    case protected: bool   # Protected datasets have erasure coded info
    of true:
      ecK: int               # Number of blocks to encode
      ecM: int               # Number of resulting parity blocks
      originalCid: Cid     # The original Cid of the dataset being erasure coded
      originalLen: int     # The length of the original manifest
    else:
      discard

############################################################
# Accessors
############################################################

proc blockSize*(self: Manifest): NBytes =
  self.blockSize

proc blocks*(self: Manifest): seq[Cid] =
  self.blocks

proc version*(self: Manifest): CidVersion =
  self.version

proc hcodec*(self: Manifest): MultiCodec =
  self.hcodec

proc codec*(self: Manifest): MultiCodec =
  self.codec

proc protected*(self: Manifest): bool =
  self.protected

proc ecK*(self: Manifest): int =
  self.ecK

proc ecM*(self: Manifest): int =
  self.ecM

proc originalCid*(self: Manifest): Cid =
  self.originalCid

proc originalLen*(self: Manifest): int =
  self.originalLen

proc originalBytes*(self: Manifest): NBytes =
  self.originalBytes

proc treeCid*(self: Manifest): Cid =
  self.treeCid

proc treeRoot*(self: Manifest): MultiHash =
  self.treeRoot

proc leavesCount*(self: Manifest): int =
  self.originalBytes.int div self.blockSize.int

func len*(self: Manifest): int =
  self.leavesCount

############################################################
# Operations on block list
############################################################

func isManifest*(cid: Cid): ?!bool =
  let res = ?cid.contentType().mapFailure(CodexError)
  ($(res) in ManifestContainers).success

func isManifest*(mc: MultiCodec): ?!bool =
  ($mc in ManifestContainers).success

############################################################
# Various sizes and verification
############################################################

func bytes*(self: Manifest, pad = true): NBytes =
  ## Compute how many bytes corresponding StoreStream(Manifest, pad) will return
  if pad or self.protected:
    self.len.NBytes * self.blockSize
  else:
    self.originalBytes

func rounded*(self: Manifest): int =
  ## Number of data blocks in *protected* manifest including padding at the end
  roundUp(self.originalLen, self.ecK)

func steps*(self: Manifest): int =
  ## Number of EC groups in *protected* manifest
  divUp(self.originalLen, self.ecK)

func verify*(self: Manifest): ?!void =
  ## Check manifest correctness
  ##

  if self.protected and (self.len != self.steps * (self.ecK + self.ecM)):
    return failure newException(CodexError, "Broken manifest: wrong originalLen")

  return success()


############################################################
# Cid computation
############################################################

proc cid*(self: Manifest): ?!Cid {.deprecated: "use treeCid instead".} =

  self.treeCid.success


############################################################
# Constructors
############################################################

proc new*(
    T: type Manifest,
    treeCid: Cid,
    treeRoot: MultiHash,
    blockSize: NBytes,
    originalBytes: NBytes,
    version: CidVersion,
    hcodec: MultiCodec,
    codec = multiCodec("raw"),
    protected = false,
): Manifest =

  T(
    treeCid: treeCid,
    treeRoot: treeRoot,
    blockSize: blockSize,
    originalBytes: originalBytes,
    version: version,
    codec: codec,
    hcodec: hcodec,
    protected: protected)

proc new*(
    T: type Manifest,
    manifest: Manifest,
    ecK, ecM: int
): ?!Manifest =
  ## Create an erasure protected dataset from an
  ## un-protected one
  ##

  var
    self = Manifest(
      version: manifest.version,
      codec: manifest.codec,
      hcodec: manifest.hcodec,
      originalBytes: manifest.originalBytes,
      blockSize: manifest.blockSize,
      protected: true,
      ecK: ecK, ecM: ecM,
      originalCid: ? manifest.cid,
      originalLen: manifest.len)

  let
    encodedLen = self.rounded + (self.steps * ecM)

  # copy original manifest blocks

  # TODO fix this:
  # for i in 0..<self.rounded:
  #   if i < manifest.len:
  #     self.blocks[i] = manifest[i]
  #   else:
  #     self.blocks[i] = EmptyCid[manifest.version]
  #     .catch
  #     .get()[manifest.hcodec]
  #     .catch
  #     .get()

  # ? self.verify()
  self.success

proc new*(
  T: type Manifest,
  data: openArray[byte],
  decoder = ManifestContainers[$DagPBCodec]
): ?!Manifest =
  ## Create a manifest instance from given data
  ##
  Manifest.decode(data, decoder)

proc new*(
  T: type Manifest,
  treeCid: Cid,
  treeRoot: MultiHash,
  originalBytes: NBytes,
  blockSize: NBytes,
  version: CidVersion,
  hcodec: MultiCodec,
  codec: MultiCodec,
  ecK: int,
  ecM: int,
  originalCid: Cid,
  originalLen: int
): Manifest =
  Manifest(
    treeCid: treeCid,
    treeRoot: treeRoot,
    originalBytes: originalBytes,
    blockSize: blockSize,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalCid: originalCid,
    originalLen: originalLen
  )

# proc new*(
#   T: type Manifest,
#   treeCid: Cid,
#   treeRoot: MultiHash,
#   originalBytes: NBytes,
#   blockSize: NBytes,
#   version: CidVersion,
#   hcodec: MultiCodec,
#   codec: MultiCodec
# ): Manifest =
#   Manifest(
#     treeCid: treeCid,
#     treeRoot: treeRoot,
#     originalBytes: originalBytes,
#     blockSize: blockSize,
#     version: version,
#     hcodec: hcodec,
#     codec: codec,
#     protected: false,
#   )
