import std/sequtils
import std/sugar
import std/random
import std/strutils

import ../../../asynctest

import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore
import pkg/codex/slots/types
import pkg/codex/slots/sampler/utils
import pkg/codex/utils/json

import ../backends/helpers
import ../../helpers
import ../../examples
import ../../merkletree/helpers

asyncchecksuite "Test proof sampler utils":
  let
    cellsPerBlock = DefaultBlockSize div DefaultCellSize

  var
    inputData: string
    inputJson: JsonNode
    proofInput: ProofInputs[Poseidon2Hash]

  setup:
    inputData = readFile("tests/circuits/fixtures/input.json")
    inputJson = !JsonNode.parse(inputData)
    proofInput = Poseidon2Hash.jsonToProofInput(inputJson)

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

  test "Can find single slot-cell index":
    proc slotCellIndex(i: Natural): Natural =
      return cellIndex(proofInput.entropy, proofInput.slotRoot, proofInput.nCellsPerSlot, i)

    proc getExpectedIndex(i: int): Natural =
      let
        hash = Sponge.digest(@[proofInput.entropy, proofInput.slotRoot, toF(i)], rate = 2)

      return int(extractLowBits(hash.toBig(), ceilingLog2(proofInput.nCellsPerSlot)))

    check:
      slotCellIndex(1) == getExpectedIndex(1)
      slotCellIndex(2) == getExpectedIndex(2)
      slotCellIndex(3) == getExpectedIndex(3)

  test "Can find sequence of slot-cell indices":
    proc slotCellIndices(n: int): seq[Natural]  =
      cellIndices(proofInput.entropy, proofInput.slotRoot, numCells = proofInput.nCellsPerSlot, n)

    proc getExpectedIndices(n: int): seq[Natural]  =
      return collect(newSeq, (for i in 1..n: cellIndex(proofInput.entropy, proofInput.slotRoot, proofInput.nCellsPerSlot, i)))

    check:
      slotCellIndices(3) == getExpectedIndices(3)

  for (input, expected) in [(10, 0), (31, 0), (32, 1), (63, 1), (64, 2)]:
    test "Can get slotBlockIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let slotBlockIndex = toBlkInSlot(input, numCells = cellsPerBlock)

      check:
        slotBlockIndex == expected

  for (input, expected) in [(10, 10), (31, 31), (32, 0), (63, 31), (64, 0)]:
    test "Can get blockCellIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let blockCellIndex = toCellInBlk(input, numCells = cellsPerBlock)

      check:
        blockCellIndex == expected
