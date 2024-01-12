import std/sequtils
import std/sugar
import std/random
import std/strutils

import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore

import pkg/codex/proof/datasampler
import pkg/codex/proof/misc
import pkg/codex/proof/types

import ../helpers
import ../examples
import ../merkletree/helpers
import testdatasampler_expected
import ./provingtestenv

asyncchecksuite "Test proof datasampler - components":
  let
    bytesPerBlock = 64 * 1024
    challenge: Poseidon2Hash = toF(12345)
    numberOfSlotBlocks = 16
    slot = Slot(
      request: StorageRequest(
        ask: StorageAsk(
          slots: 10,
          slotSize: u256(bytesPerBlock * numberOfSlotBlocks),
        ),
        content: StorageContent(
          cid: $Cid.example
        )
      ),
      slotIndex: u256(3)
    )

  test "Extract low bits":
    proc extract(value: uint64, nBits: int): uint64 =
      let big = toF(value).toBig()
      return extractLowBits(big, nBits)

    check:
      extract(0x88, 4) == 0x8.uint64
      extract(0x88, 7) == 0x8.uint64
      extract(0x9A, 5) == 0x1A.uint64
      extract(0x9A, 7) == 0x1A.uint64
      extract(0x1248, 10) == 0x248.uint64
      extract(0x1248, 12) == 0x248.uint64
      extract(0x1248306A560C9AC0.uint64, 10) == 0x2C0.uint64
      extract(0x1248306A560C9AC0.uint64, 12) == 0xAC0.uint64
      extract(0x1248306A560C9AC0.uint64, 50) == 0x306A560C9AC0.uint64
      extract(0x1248306A560C9AC0.uint64, 52) == 0x8306A560C9AC0.uint64

  test "Should calculate total number of cells in Slot":
    let
      slotSizeInBytes = (slot.request.ask.slotSize).truncate(uint64)
      expectedNumberOfCells = slotSizeInBytes div DefaultCellSize.uint64

    check:
      expectedNumberOfCells == 512
      expectedNumberOfCells == getNumberOfCellsInSlot(slot)

asyncchecksuite "Test proof datasampler - main":
  var
    env: ProvingTestEnvironment
    dataSampler: DataSampler
    blk: bt.Block
    cell0Bytes: seq[byte]
    cell1Bytes: seq[byte]
    cell2Bytes: seq[byte]

  proc createDataSampler(): Future[void] {.async.} =
    dataSampler = DataSampler.new(
      env.slot,
      env.localStore
    )
    (await dataSampler.start()).tryGet()

  setup:
    env = await createProvingTestEnvironment()
    let bytes = newSeqWith(bytesPerBlock, rand(uint8))
    blk = bt.Block.new(bytes).tryGet()
    cell0Bytes = bytes[0..<DefaultCellSize.uint64]
    cell1Bytes = bytes[DefaultCellSize.uint64..<(DefaultCellSize.uint64*2)]
    cell2Bytes = bytes[(DefaultCellSize.uint64*2)..<(DefaultCellSize.uint64*3)]

    await createDataSampler()

  teardown:
    reset(env)
    reset(dataSampler)

  test "Can get cell from block":
    let
      sample0 = dataSampler.getCellFromBlock(blk, 0)
      sample1 = dataSampler.getCellFromBlock(blk, 1)
      sample2 = dataSampler.getCellFromBlock(blk, 2)

    check:
      sample0 == cell0Bytes
      sample1 == cell1Bytes
      sample2 == cell2Bytes

  test "Can create mini tree for block cells":
    let miniTree = dataSampler.getBlockCellMiniTree(blk).tryGet()

    let
      cell0Proof = miniTree.getProof(0).tryGet()
      cell1Proof = miniTree.getProof(1).tryGet()
      cell2Proof = miniTree.getProof(2).tryGet()

      cell0Hash = Sponge.digest(cell0Bytes, rate = 2)
      cell1Hash = Sponge.digest(cell1Bytes, rate = 2)
      cell2Hash = Sponge.digest(cell2Bytes, rate = 2)

      root = miniTree.root().tryGet()

    check:
      not cell0Proof.verify(cell0Hash, root).isErr()
      not cell1Proof.verify(cell1Hash, root).isErr()
      not cell2Proof.verify(cell2Hash, root).isErr()

  test "Can gather proof input":
    let
      nSamples = 3
      challengeBytes = env.challenge.toBytes()
      input = (await dataSampler.getProofInput(challengeBytes, nSamples)).tryget()

    proc equal(a: Poseidon2Hash, b: Poseidon2Hash): bool =
      a.toDecimal() == b.toDecimal()

    proc toStr(proof: Poseidon2Proof): string =
      let a = proof.path.mapIt(toHex(it))
      join(a)

    let
      expectedBlockSlotProofs = getExpectedBlockSlotProofs()
      expectedCellBlockProofs = getExpectedCellBlockProofs()
      expectedCellData = getExpectedCellData()
      expectedProof = env.datasetToSlotTree.getProof(datasetSlotIndex).tryGet()

    check:
      equal(input.datasetRoot, env.datasetRootHash)
      equal(input.entropy, env.challenge)
      input.numberOfCellsInSlot == (bytesPerBlock * numberOfSlotBlocks).uint64 div DefaultCellSize.uint64
      input.numberOfSlots == env.slot.request.ask.slots
      input.datasetSlotIndex == env.slot.slotIndex.truncate(uint64)
      equal(input.slotRoot, env.slotTree.root().tryGet())
      input.datasetToSlotProof == expectedProof

      # block-slot proofs
      input.proofSamples[0].slotBlockIndex == 2
      input.proofSamples[1].slotBlockIndex == 2
      input.proofSamples[2].slotBlockIndex == 0
      toStr(input.proofSamples[0].blockSlotProof) == expectedBlockSlotProofs[0]
      toStr(input.proofSamples[1].blockSlotProof) == expectedBlockSlotProofs[1]
      toStr(input.proofSamples[2].blockSlotProof) == expectedBlockSlotProofs[2]

      # cell-block proofs
      input.proofSamples[0].blockCellIndex == 26
      input.proofSamples[1].blockCellIndex == 29
      input.proofSamples[2].blockCellIndex == 29
      toStr(input.proofSamples[0].cellBlockProof) == expectedCellBlockProofs[0]
      toStr(input.proofSamples[1].cellBlockProof) == expectedCellBlockProofs[1]
      toStr(input.proofSamples[2].cellBlockProof) == expectedCellBlockProofs[2]

      # cell data
      toHex(input.proofSamples[0].cellData) == expectedCellData[0]
      toHex(input.proofSamples[1].cellData) == expectedCellData[1]
      toHex(input.proofSamples[2].cellData) == expectedCellData[2]
