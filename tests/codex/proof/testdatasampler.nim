import std/os
import std/strutils
import std/sequtils
import std/sugar
import std/random

import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2/types
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/stew/byteutils
import pkg/stew/endians2
import pkg/datastore
import pkg/codex/rng
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/clock
import pkg/codex/utils/asynciter
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore

import pkg/codex/proof/datasampler
import pkg/codex/proof/misc
import pkg/codex/proof/types
#import pkg/codex/proof/indexing

import ../helpers
import ../examples

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 16
  challenge: DSFieldElement = toF(12345)
  slotRootHash: DSFieldElement = toF(6789)
  slot = Slot(
    request: StorageRequest(
      client: Address.example,
      ask: StorageAsk(
        slots: 10,
        slotSize: u256(bytesPerBlock * numberOfSlotBlocks),
        duration: UInt256.example,
        proofProbability: UInt256.example,
        reward: UInt256.example,
        collateral: UInt256.example,
        maxSlotLoss: 123.uint64
      ),
      content: StorageContent(
        cid: "cidstringtodo",
        erasure: StorageErasure(),
        por: StoragePoR()
      ),
      expiry: UInt256.example,
      nonce: Nonce.example
    ),
    slotIndex: u256(3)
  )

asyncchecksuite "Test proof datasampler":
  let chunker = RandomChunker.new(rng.Rng.instance(),
    size = bytesPerBlock * numberOfSlotBlocks,
    chunkSize = bytesPerBlock)

  var slotBlocks: seq[bt.Block]

  proc createSlotBlocks(): Future[void] {.async.} =
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      slotBlocks.add(bt.Block.new(chunk).tryGet())

  setup:
    await createSlotBlocks()

  test "Number of cells is a power of two":
    # This is to check that the data used for testing is sane.
    proc isPow2(value: int): bool =
      let log2 = ceilingLog2(value)
      return (1 shl log2) == value

    let numberOfCells = getNumberOfCellsInSlot(slot).int

    check:
      isPow2(numberOfCells)

  test "Extract low bits":
    proc extract(value: int, nBits: int): uint64 =
      let big = toF(value).toBig()
      return extractLowBits(big, nBits)

    check:
      extract(0x88, 4) == 0x8.uint64
      extract(0x88, 7) == 0x8.uint64
      extract(0x9A, 5) == 0x1A.uint64
      extract(0x9A, 7) == 0x1A.uint64
      extract(0x1248, 10) == 0x248.uint64
      extract(0x1248, 12) == 0x248.uint64
      # extract(0x1248306A560C9AC0, 10) == 0x2C0.uint64
      # extract(0x1248306A560C9AC0, 12) == 0xAC0.uint64
      # extract(0x1248306A560C9AC0, 50) == 0x306A560C9AC0.uint64
      # extract(0x1248306A560C9AC0, 52) == 0x8306A560C9AC0.uint64

  test "Should calculate total number of cells in Slot":
    let
      slotSizeInBytes = (slot.request.ask.slotSize).truncate(uint64)
      expectedNumberOfCells = slotSizeInBytes div CellSize

    check:
      expectedNumberOfCells == 512
      expectedNumberOfCells == getNumberOfCellsInSlot(slot)

  let knownIndices = @[178.uint64, 277.uint64, 366.uint64]

  test "Can find single slot-cell index":
    let numberOfCells = getNumberOfCellsInSlot(slot)

    proc slotCellIndex(i: int): DSSlotCellIndex =
      let counter: DSFieldElement = toF(i)
      return findSlotCellIndex(slotRootHash, challenge, counter, numberOfCells)

    proc getExpectedIndex(i: int): DSSlotCellIndex =
      let hash = Sponge.digest(@[slotRootHash, challenge, toF(i)], rate = 2)
      return extractLowBits(hash.toBig(), ceilingLog2(numberOfCells.int))

    check:
      slotCellIndex(1) == getExpectedIndex(1)
      slotCellIndex(1) == knownIndices[0]
      slotCellIndex(2) == getExpectedIndex(2)
      slotCellIndex(2) == knownIndices[1]
      slotCellIndex(3) == getExpectedIndex(3)
      slotCellIndex(3) == knownIndices[2]

  test "Can find sequence of slot-cell indices":
    proc slotCellIndices(n: int): seq[DSSlotCellIndex]  =
      findSlotCellIndices(slot, slotRootHash, challenge, n)

    let numberOfCells = getNumberOfCellsInSlot(slot)
    proc getExpectedIndices(n: int): seq[DSSlotCellIndex]  =
      return collect(newSeq, (for i in 1..n: findSlotCellIndex(slotRootHash, challenge, toF(i), numberOfCells)))

    check:
      slotCellIndices(3) == getExpectedIndices(3)
      slotCellIndices(3) == knownIndices

  test "Can get cell from block":
    let
      blockSize = CellSize * 3
      bytes = newSeqWith(blockSize.int, rand(uint8))
      blk = bt.Block.new(bytes).tryGet()

      sample0 = getCellFromBlock(blk, 0, blockSize.uint64)
      sample1 = getCellFromBlock(blk, 1, blockSize.uint64)
      sample2 = getCellFromBlock(blk, 2, blockSize.uint64)

    check:
      sample0 == bytes[0..<CellSize]
      sample1 == bytes[CellSize..<(CellSize*2)]
      sample2 == bytes[(CellSize*2)..^1]

  test "Can convert block into cells":
    let
      blockSize = CellSize * 3
      bytes = newSeqWith(blockSize.int, rand(uint8))
      blk = bt.Block.new(bytes).tryGet()

      cells = getBlockCells(blk, blockSize)

    check:
      cells.len == 3
      cells[0] == bytes[0..<CellSize]
      cells[1] == bytes[CellSize..<(CellSize*2)]
      cells[2] == bytes[(CellSize*2)..^1]

  test "Can create mini tree for block cells":
    let
      blockSize = CellSize * 3
      bytes = newSeqWith(blockSize.int, rand(uint8))
      blk = bt.Block.new(bytes).tryGet()
      cell0Bytes = bytes[0..<CellSize]
      cell1Bytes = bytes[CellSize..<(CellSize*2)]
      cell2Bytes = bytes[(CellSize*2)..^1]

      miniTree = getBlockCellMiniTree(blk, blockSize).tryGet()

    let
      cell0Proof = miniTree.getProof(0).tryGet()
      cell1Proof = miniTree.getProof(1).tryGet()
      cell2Proof = miniTree.getProof(2).tryGet()

    check:
      cell0Proof.verifyDataBlock(cell0Bytes, miniTree.root).tryGet()
      cell1Proof.verifyDataBlock(cell1Bytes, miniTree.root).tryGet()
      cell2Proof.verifyDataBlock(cell2Bytes, miniTree.root).tryGet()

  test "Can gather proof input":
    # This is the main entry point for this module, and what it's all about.
    let
      localStore = CacheStore.new()
      datasetToSlotProof = MerkleProof.example
      slotPoseidonTree = MerkleTree.init(@[Cid.example]).tryget()
      nSamples = 3

      a = (await getProofInput(
        slot,
        localStore,
        slotRootHash,
        slotPoseidonTree,
        datasetToSlotProof,
        challenge,
        nSamples)).tryget()

    echo "a.slotToBlockProofs: " & $a.slotToBlockProofs.len
    echo "a.blockToCellProofs: " & $a.blockToCellProofs.len
    echo "a.sampleData: " & $a.sampleData.len
