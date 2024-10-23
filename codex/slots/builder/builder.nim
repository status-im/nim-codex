## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/math
import std/sequtils
import std/sugar

import pkg/libp2p
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/io/io_fields

import ../../logutils
import ../../utils
import ../../stores
import ../../manifest
import ../../merkletree
import ../../utils/digest
import ../../utils/asynciter
import ../../indexingstrategy

import ../converters

export converters, asynciter

logScope:
  topics = "codex slotsbuilder"

type
  SlotsBuilder*[T, H] = ref object of RootObj
    store: BlockStore
    manifest: Manifest            # current manifest
    strategy: IndexingStrategy    # indexing strategy
    cellSize: NBytes              # cell size
    numSlotBlocks: Natural        # number of blocks per slot (should yield a power of two number of cells)
    slotRoots: seq[H]             # roots of the slots
    emptyBlock: seq[byte]         # empty block
    verifiableTree: ?T            # verification tree (dataset tree)
    emptyDigestTree: T            # empty digest tree for empty blocks

func verifiable*[T, H](self: SlotsBuilder[T, H]): bool {.inline.} =
  ## Returns true if the slots are verifiable.
  ##

  self.manifest.verifiable

func slotRoots*[T, H](self: SlotsBuilder[T, H]): seq[H] {.inline.} =
  ## Returns the slot roots.
  ##

  self.slotRoots

func verifyTree*[T, H](self: SlotsBuilder[T, H]): ?T {.inline.} =
  ## Returns the slots tree (verification tree).
  ##

  self.verifiableTree

func verifyRoot*[T, H](self: SlotsBuilder[T, H]): ?H {.inline.} =
  ## Returns the slots root (verification root).
  ##

  if tree =? self.verifyTree and root =? tree.root:
    return some root

func numSlots*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of slots.
  ##

  self.manifest.numSlots

func numSlotBlocks*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of blocks per slot.
  ##

  self.numSlotBlocks

func numBlocks*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of blocks.
  ##

  self.numSlotBlocks * self.manifest.numSlots

func slotBytes*[T, H](self: SlotsBuilder[T, H]): NBytes =
  ## Number of bytes per slot.
  ##

  (self.manifest.blockSize.int * self.numSlotBlocks).NBytes

func numBlockCells*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of cells per block.
  ##

  (self.manifest.blockSize div self.cellSize).Natural

func cellSize*[T, H](self: SlotsBuilder[T, H]): NBytes =
  ## Cell size.
  ##

  self.cellSize

func numSlotCells*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of cells per slot.
  ##

  self.numBlockCells * self.numSlotBlocks

func slotIndiciesIter*[T, H](self: SlotsBuilder[T, H], slot: Natural): ?!Iter[int] =
  ## Returns the slot indices.
  ##

  self.strategy.getIndicies(slot).catch

func slotIndicies*[T, H](self: SlotsBuilder[T, H], slot: Natural): seq[int] =
  ## Returns the slot indices.
  ##

  if iter =? self.strategy.getIndicies(slot).catch:
    return toSeq(iter)

func manifest*[T, H](self: SlotsBuilder[T, H]): Manifest =
  ## Returns the manifest.
  ##

  self.manifest

proc buildBlockTree*[T, H](
  self: SlotsBuilder[T, H],
  blkIdx: Natural,
  slotPos: Natural): Future[?!(seq[byte], T)] {.async.} =
  ## Build the block digest tree and return a tuple with the
  ## block data and the tree.
  ##

  logScope:
    blkIdx = blkIdx
    slotPos = slotPos
    numSlotBlocks = self.manifest.numSlotBlocks
    cellSize = self.cellSize

  trace "Building block tree"

  if slotPos > (self.manifest.numSlotBlocks - 1):
    # pad blocks are 0 byte blocks
    trace "Returning empty digest tree for pad block"
    return success (self.emptyBlock, self.emptyDigestTree)

  without blk =? await self.store.getBlock(self.manifest.treeCid, blkIdx), err:
    error "Failed to get block CID for tree at index", err = err.msg
    return failure(err)

  if blk.isEmpty:
    success (self.emptyBlock, self.emptyDigestTree)
  else:
    without tree =?
      T.digestTree(blk.data, self.cellSize.int), err:
      error "Failed to create digest for block", err = err.msg
      return failure(err)

    success (blk.data, tree)

proc getCellHashes*[T, H](
  self: SlotsBuilder[T, H],
  slotIndex: Natural): Future[?!seq[H]] {.async.} =
  ## Collect all the cells from a block and return
  ## their hashes.
  ##

  let
    treeCid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount
    numberOfSlots = self.manifest.numSlots

  logScope:
    treeCid = treeCid
    origBlockCount = blockCount
    numberOfSlots = numberOfSlots
    slotIndex = slotIndex

  let hashes = collect(newSeq):
    for i, blkIdx in self.strategy.getIndicies(slotIndex):
      logScope:
        blkIdx = blkIdx
        pos = i

      trace "Getting block CID for tree at index"
      without (_, tree) =? (await self.buildBlockTree(blkIdx, i)) and
        digest =? tree.root, err:
        error "Failed to get block CID for tree at index", err = err.msg
        return failure(err)

      trace "Get block digest", digest = digest.toHex
      digest

  success hashes

proc buildSlotTree*[T, H](
  self: SlotsBuilder[T, H],
  slotIndex: Natural): Future[?!T] {.async.} =
  ## Build the slot tree from the block digest hashes
  ## and return the tree.

  without cellHashes =? (await self.getCellHashes(slotIndex)), err:
    error "Failed to select slot blocks", err = err.msg
    return failure(err)

  T.init(cellHashes)

proc buildSlot*[T, H](
  self: SlotsBuilder[T, H],
  slotIndex: Natural): Future[?!H] {.async.} =
  ## Build a slot tree and store the proofs in
  ## the block store.
  ##

  logScope:
    cid         = self.manifest.treeCid
    slotIndex   = slotIndex

  trace "Building slot tree"

  without tree =? (await self.buildSlotTree(slotIndex)) and
    treeCid =? tree.root.?toSlotCid, err:
    error "Failed to build slot tree", err = err.msg
    return failure(err)

  trace "Storing slot tree", treeCid, slotIndex, leaves = tree.leavesCount
  for i, leaf in tree.leaves:
    without cellCid =? leaf.toCellCid, err:
      error "Failed to get CID for slot cell", err = err.msg
      return failure(err)

    without proof =? tree.getProof(i) and
      encodableProof =? proof.toEncodableProof, err:
      error "Failed to get proof for slot tree", err = err.msg
      return failure(err)

    if err =? (await self.store.putCidAndProof(
      treeCid, i, cellCid, encodableProof)).errorOption:
      error "Failed to store slot tree", err = err.msg
      return failure(err)

  tree.root()

func buildVerifyTree*[T, H](self: SlotsBuilder[T, H], slotRoots: openArray[H]): ?!T =
  T.init(@slotRoots)

proc buildSlots*[T, H](self: SlotsBuilder[T, H]): Future[?!void] {.async.} =
  ## Build all slot trees and store them in the block store.
  ##

  logScope:
    cid         = self.manifest.treeCid
    blockCount  = self.manifest.blocksCount

  trace "Building slots"

  if self.slotRoots.len == 0:
    self.slotRoots = collect(newSeq):
      for i in 0..<self.manifest.numSlots:
        without slotRoot =? (await self.buildSlot(i)), err:
          error "Failed to build slot", err = err.msg, index = i
          return failure(err)
        slotRoot

  without tree =? self.buildVerifyTree(self.slotRoots) and root =? tree.root, err:
    error "Failed to build slot roots tree", err = err.msg
    return failure(err)

  if verifyTree =? self.verifyTree and verifyRoot =? verifyTree.root:
    if not bool(verifyRoot == root): # TODO: `!=` doesn't work for SecretBool
        return failure "Existing slots root doesn't match reconstructed root."

  self.verifiableTree = some tree

  success()

proc buildManifest*[T, H](self: SlotsBuilder[T, H]): Future[?!Manifest] {.async.} =
  if err =? (await self.buildSlots()).errorOption:
    error "Failed to build slot roots", err = err.msg
    return failure(err)

  without rootCids =? self.slotRoots.toSlotCids(), err:
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  without rootProvingCidRes =? self.verifyRoot.?toVerifyCid() and
    rootProvingCid =? rootProvingCidRes, err: # TODO: why doesn't `.?` unpack the result?
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  Manifest.new(
    self.manifest,
    rootProvingCid,
    rootCids,
    self.cellSize,
    self.strategy.strategyType)

proc new*[T, H](
  _: type SlotsBuilder[T, H],
  store: BlockStore,
  manifest: Manifest,
  strategy = SteppedStrategy,
  cellSize = DefaultCellSize): ?!SlotsBuilder[T, H] =

  if not manifest.protected:
    trace "Manifest is not protected."
    return failure("Manifest is not protected.")

  logScope:
    blockSize = manifest.blockSize
    strategy = strategy
    cellSize = cellSize

  if (manifest.blocksCount mod manifest.numSlots) != 0:
    trace "Number of blocks must be divisable by number of slots."
    return failure("Number of blocks must be divisable by number of slots.")

  let cellSize = if manifest.verifiable: manifest.cellSize else: cellSize
  if (manifest.blockSize mod cellSize) != 0.NBytes:
    trace "Block size must be divisable by cell size."
    return failure("Block size must be divisable by cell size.")

  let
    numSlotBlocks     = manifest.numSlotBlocks
    numBlockCells     = (manifest.blockSize div cellSize).int             # number of cells per block
    numSlotCells      = manifest.numSlotBlocks * numBlockCells            # number of uncorrected slot cells
    pow2SlotCells     = nextPowerOfTwo(numSlotCells)                      # pow2 cells per slot
    numPadSlotBlocks  = (pow2SlotCells div numBlockCells) - numSlotBlocks # pow2 blocks per slot

    numSlotBlocksTotal  =                                                 # pad blocks per slot
      if numPadSlotBlocks > 0:
          numPadSlotBlocks + numSlotBlocks
        else:
          numSlotBlocks

    numBlocksTotal      = numSlotBlocksTotal * manifest.numSlots          # number of blocks per slot

    emptyBlock          = newSeq[byte](manifest.blockSize.int)
    emptyDigestTree     = ? T.digestTree(emptyBlock, cellSize.int)

    strategy = ? strategy.init(
      0,
      numBlocksTotal - 1,
      manifest.numSlots).catch

  logScope:
    numSlotBlocks       = numSlotBlocks
    numBlockCells       = numBlockCells
    numSlotCells        = numSlotCells
    pow2SlotCells       = pow2SlotCells
    numPadSlotBlocks    = numPadSlotBlocks
    numBlocksTotal      = numBlocksTotal
    numSlotBlocksTotal  = numSlotBlocksTotal
    strategy            = strategy.strategyType

  trace "Creating slots builder"

  var
    self = SlotsBuilder[T, H](
      store: store,
      manifest: manifest,
      strategy: strategy,
      cellSize: cellSize,
      emptyBlock: emptyBlock,
      numSlotBlocks: numSlotBlocksTotal,
      emptyDigestTree: emptyDigestTree)

  if manifest.verifiable:
    if manifest.slotRoots.len == 0 or
      manifest.slotRoots.len != manifest.numSlots:
      return failure "Manifest is verifiable but slot roots are missing or invalid."

    let
      slotRoots = manifest.slotRoots.mapIt( (? it.fromSlotCid() ))
      tree = ? self.buildVerifyTree(slotRoots)
      expectedRoot = ? manifest.verifyRoot.fromVerifyCid()
      verifyRoot = ? tree.root

    if verifyRoot != expectedRoot:
      return failure "Existing slots root doesn't match reconstructed root."

    self.slotRoots = slotRoots
    self.verifiableTree = some tree

  success self
