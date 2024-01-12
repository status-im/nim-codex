import std/sequtils

import pkg/questionable/results
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore
import pkg/codex/indexingstrategy

import pkg/codex/proof/proofpadding
import pkg/codex/slots/converters
import pkg/codex/utils/poseidon2digest

import ../helpers
import ../merkletree/helpers

type
  ProvingTestEnvironment* = ref object
    # Invariant:
    challenge*: Poseidon2Hash
    # Variant:
    localStore*: CacheStore
    manifest*: Manifest
    manifestBlock*: bt.Block
    slot*: Slot
    datasetBlocks*: seq[bt.Block]
    slotTree*: Poseidon2Tree
    slotRootCid*: Cid
    slotRoots*: seq[Poseidon2Hash]
    datasetToSlotTree*: Poseidon2Tree
    datasetRootHash*: Poseidon2Hash

const
  # The number of slot blocks and number of slots, combined with
  # the bytes per block, make it so that there are exactly 256 cells
  # in the dataset.
  bytesPerBlock* = 64 * 1024
  numberOfSlotBlocks* = 4
  totalNumberOfSlots* = 2
  datasetSlotIndex* = 1

proc createDatasetBlocks(self: ProvingTestEnvironment): Future[void] {.async.} =
  let numberOfCellsNeeded = (numberOfSlotBlocks * totalNumberOfSlots * bytesPerBlock).uint64 div DefaultCellSize.uint64
  var data: seq[byte] = @[]

  # This generates a number of blocks that have different data, such that
  # Each cell in each block is unique, but nothing is random.
  for i in 0 ..< numberOfCellsNeeded:
    data = data & (i.byte).repeat(DefaultCellSize.uint64)

  let chunker = MockChunker.new(
    dataset = data,
    chunkSize = bytesPerBlock)

  while true:
    let chunk = await chunker.getBytes()
    if chunk.len <= 0:
      break
    let b = bt.Block.new(chunk).tryGet()
    self.datasetBlocks.add(b)
    discard await self.localStore.putBlock(b)

proc createSlotTree(self: ProvingTestEnvironment, dSlotIndex: uint64): Future[Poseidon2Tree] {.async.} =
  let
    slotSize = (bytesPerBlock * numberOfSlotBlocks).uint64
    blocksInSlot = slotSize div bytesPerBlock.uint64
    datasetBlockIndexingStrategy = SteppedIndexingStrategy.new(0, self.datasetBlocks.len - 1, totalNumberOfSlots)
    datasetBlockIndices = datasetBlockIndexingStrategy.getIndicies(dSlotIndex.int)

  let
    slotBlocks = datasetBlockIndices.mapIt(self.datasetBlocks[it])
    slotBlockRoots = slotBlocks.mapIt(Poseidon2Tree.digest(it.data, DefaultCellSize.int).tryGet())
    tree = Poseidon2Tree.init(slotBlockRoots).tryGet()
    treeCid = tree.root().tryGet().toSlotCid().tryGet()

  for i in 0 ..< numberOfSlotBlocks:
    let
      blkCid = slotBlockRoots[i].toCellCid().tryGet()
      proof = tree.getProof(i).tryGet().toEncodableProof().tryGet()

    discard await self.localStore.putCidAndProof(treeCid, i, blkCid, proof)

  return tree

proc createDatasetRootHashAndSlotTree(self: ProvingTestEnvironment): Future[void] {.async.} =
  var slotTrees = newSeq[Poseidon2Tree]()
  for i in 0 ..< totalNumberOfSlots:
    slotTrees.add(await self.createSlotTree(i.uint64))
  self.slotTree = slotTrees[datasetSlotIndex]
  self.slotRootCid = slotTrees[datasetSlotIndex].root().tryGet().toSlotCid().tryGet()
  self.slotRoots = slotTrees.mapIt(it.root().tryGet())
  let rootsPadLeafs = newSeqWith(totalNumberOfSlots.nextPowerOfTwoPad, Poseidon2Zero)
  self.datasetToSlotTree = Poseidon2Tree.init(self.slotRoots & rootsPadLeafs).tryGet()
  self.datasetRootHash = self.datasetToSlotTree.root().tryGet()

proc createManifest(self: ProvingTestEnvironment): Future[void] {.async.} =
  let
    cids = self.datasetBlocks.mapIt(it.cid)
    tree = CodexTree.init(cids).tryGet()
    treeCid = tree.rootCid(CIDv1, BlockCodec).tryGet()

  for i in 0 ..< self.datasetBlocks.len:
    let
      blk = self.datasetBlocks[i]
      leafCid = blk.cid
      proof = tree.getProof(i).tryGet()
    discard await self.localStore.putBlock(blk)
    discard await self.localStore.putCidAndProof(treeCid, i, leafCid, proof)

  # Basic manifest:
  self.manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = bytesPerBlock.NBytes,
    datasetSize = (bytesPerBlock * numberOfSlotBlocks * totalNumberOfSlots).NBytes)

  # Protected manifest:
  self.manifest = Manifest.new(
    manifest = self.manifest,
    treeCid = treeCid,
    datasetSize = self.manifest.datasetSize,
    ecK = totalNumberOfSlots,
    ecM = 0
  )

  # Verifiable manifest:
  self.manifest = Manifest.new(
    manifest = self.manifest,
    verifyRoot = self.datasetRootHash.toProvingCid().tryGet(),
    slotRoots = self.slotRoots.mapIt(it.toSlotCid().tryGet())
  ).tryGet()

  self.manifestBlock = bt.Block.new(self.manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
  discard await self.localStore.putBlock(self.manifestBlock)

proc createSlot(self: ProvingTestEnvironment): void =
  self.slot = Slot(
    request: StorageRequest(
      ask: StorageAsk(
        slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
      ),
      content: StorageContent(
        cid: $self.manifestBlock.cid
      ),
    ),
    slotIndex: u256(datasetSlotIndex)
  )

proc createProvingTestEnvironment*(): Future[ProvingTestEnvironment] {.async.} =
  var testEnv = ProvingTestEnvironment(
    challenge: toF(12345)
  )

  testEnv.localStore = CacheStore.new()
  await testEnv.createDatasetBlocks()
  await testEnv.createDatasetRootHashAndSlotTree()
  await testEnv.createManifest()
  testEnv.createSlot()

  return testEnv
