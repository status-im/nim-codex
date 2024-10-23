
import std/sequtils
import std/sugar
import std/strutils
import std/options

import pkg/poseidon2
import pkg/poseidon2/io
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields

import pkg/codex/merkletree
import pkg/codex/slots
import pkg/codex/slots/types
import pkg/codex/utils/json

export types

func toJsonDecimal*(big: BigInt[254]): string =
  let s = big.toDecimal.strip( leading = true, trailing = false, chars = {'0'} )
  if s.len == 0: "0" else: s

func toJson*(g1: CircomG1): JsonNode =
  %* {
    "x": Bn254Fr.fromBytes(g1.x).get.toBig.toJsonDecimal,
    "y": Bn254Fr.fromBytes(g1.y).get.toBig.toJsonDecimal
  }

func toJson*(g2: CircomG2): JsonNode =
  %* {
    "x": [
      Bn254Fr.fromBytes(g2.x[0]).get.toBig.toJsonDecimal,
      Bn254Fr.fromBytes(g2.x[1]).get.toBig.toJsonDecimal],
    "y": [
      Bn254Fr.fromBytes(g2.y[0]).get.toBig.toJsonDecimal,
      Bn254Fr.fromBytes(g2.y[1]).get.toBig.toJsonDecimal]
  }

proc toJson*(vpk: VerifyingKey): JsonNode =
  let
    ic = toSeq(cast[ptr UncheckedArray[CircomG1]](vpk.ic).toOpenArray(0, vpk.icLen.int - 1))

  echo ic.len
  %* {
    "alpha1": vpk.alpha1.toJson,
    "beta2": vpk.beta2.toJson,
    "gamma2": vpk.gamma2.toJson,
    "delta2": vpk.delta2.toJson,
    "ic": ic.mapIt( it.toJson )
  }

func toJson*(input: ProofInputs[Poseidon2Hash]): JsonNode =
  var
    input = input

  %* {
    "dataSetRoot": input.datasetRoot.toBig.toJsonDecimal,
    "entropy": input.entropy.toBig.toJsonDecimal,
    "nCellsPerSlot": input.nCellsPerSlot,
    "nSlotsPerDataSet": input.nSlotsPerDataSet,
    "slotIndex": input.slotIndex,
    "slotRoot": input.slotRoot.toDecimal,
    "slotProof": input.slotProof.mapIt( it.toBig.toJsonDecimal ),
    "cellData": input.samples.mapIt(
      it.cellData.mapIt( it.toBig.toJsonDecimal )
    ),
    "merklePaths": input.samples.mapIt(
      it.merklePaths.mapIt( it.toBig.toJsonDecimal )
    )
  }

func toJson*(input: NormalizedProofInputs[Poseidon2Hash]): JsonNode =
  toJson(ProofInputs[Poseidon2Hash](input))

func jsonToProofInput*(_: type Poseidon2Hash, inputJson: JsonNode): ProofInputs[Poseidon2Hash] =
  let
    cellData =
      inputJson["cellData"].mapIt(
          it.mapIt(
            block:
              var
                big: BigInt[256]
                hash: Poseidon2Hash
                data: array[32, byte]
              assert bool(big.fromDecimal( it.str ))
              assert data.marshal(big, littleEndian)

              Poseidon2Hash.fromBytes(data).get
          ).concat # flatten out elements
        )

    merklePaths =
        inputJson["merklePaths"].mapIt(
          it.mapIt(
            block:
              var
                big: BigInt[254]
                hash: Poseidon2Hash
              assert bool(big.fromDecimal( it.getStr ))
              hash.fromBig( big )
              hash
          )
        )

    slotProof = inputJson["slotProof"].mapIt(
      block:
        var
          big: BigInt[254]
          hash: Poseidon2Hash
        assert bool(big.fromDecimal( it.str ))
        hash.fromBig( big )
        hash
      )

    datasetRoot = block:
      var
        big: BigInt[254]
        hash: Poseidon2Hash
      assert bool(big.fromDecimal( inputJson["dataSetRoot"].str ))
      hash.fromBig( big )
      hash

    slotRoot = block:
      var
        big: BigInt[254]
        hash: Poseidon2Hash
      assert bool(big.fromDecimal( inputJson["slotRoot"].str ))
      hash.fromBig( big )
      hash

    entropy = block:
      var
        big: BigInt[254]
        hash: Poseidon2Hash
      assert bool(big.fromDecimal( inputJson["entropy"].str ))
      hash.fromBig( big )
      hash

    nCellsPerSlot = inputJson["nCellsPerSlot"].getInt
    nSlotsPerDataSet = inputJson["nSlotsPerDataSet"].getInt
    slotIndex = inputJson["slotIndex"].getInt

  ProofInputs[Poseidon2Hash](
    entropy: entropy,
    slotIndex: slotIndex,
    datasetRoot: datasetRoot,
    slotProof: slotProof,
    slotRoot: slotRoot,
    nCellsPerSlot: nCellsPerSlot,
    nSlotsPerDataSet: nSlotsPerDataSet,
    samples: zip(cellData, merklePaths)
      .mapIt(Sample[Poseidon2Hash](
        cellData: it[0],
        merklePaths: it[1]
      ))
  )
