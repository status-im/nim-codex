
import std/sequtils
import std/sugar
import std/options

import ../../../asynctest

import pkg/chronos
import pkg/poseidon2
import pkg/datastore
import pkg/serde/json

import pkg/codex/slots {.all.}
import pkg/codex/slots/types {.all.}
import pkg/codex/merkletree
import pkg/codex/codextypes
import pkg/codex/manifest
import pkg/codex/stores

import ./helpers
import ../helpers

suite "Test Circom Compat Backend - control inputs":
  let
    r1cs = "tests/circuits/fixtures/proof_main.r1cs"
    wasm = "tests/circuits/fixtures/proof_main.wasm"
    zkey = "tests/circuits/fixtures/proof_main.zkey"

  var
    circom: CircomCompat
    proofInputs: ProofInputs[Poseidon2Hash]

  setup:
    let
      inputData = readFile("tests/circuits/fixtures/input.json")
      inputJson = !JsonNode.parse(inputData)
      params = CircomCompatParams.init(r1cs, wasm, zkey)

    proofInputs = Poseidon2Hash.jsonToProofInput(inputJson)
    circom = CircomCompat.init(params)

  teardown:
    circom.release()  # this comes from the rust FFI

  test "Should verify with correct inputs":
    let
      proof = circom.prove(proofInputs).tryGet

    check circom.verify(proof, proofInputs).tryGet

  test "Should not verify with incorrect inputs":
    proofInputs.slotIndex = 1 # change slot index

    let
      proof = circom.prove(proofInputs).tryGet

    check circom.verify(proof, proofInputs).tryGet == false

suite "Test Circom Compat Backend":
  let
    ecK = 2
    ecM = 2
    slotId = 3
    samples = 5
    numDatasetBlocks = 8
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize

    r1cs = "tests/circuits/fixtures/proof_main.r1cs"
    wasm = "tests/circuits/fixtures/proof_main.wasm"
    zkey = "tests/circuits/fixtures/proof_main.zkey"

  var
    store: BlockStore
    manifest: Manifest
    protected: Manifest
    verifiable: Manifest
    circom: CircomCompat
    proofInputs: ProofInputs[Poseidon2Hash]
    challenge: array[32, byte]
    builder: Poseidon2Builder
    sampler: Poseidon2Sampler

  setup:
    let
      repoDs = SQLiteDatastore.new(Memory).tryGet()
      metaDs = SQLiteDatastore.new(Memory).tryGet()

    store = RepoStore.new(repoDs, metaDs)

    (manifest, protected, verifiable) =
        await createVerifiableManifest(
          store,
          numDatasetBlocks,
          ecK, ecM,
          blockSize,
          cellSize)

    builder = Poseidon2Builder.new(store, verifiable).tryGet
    sampler = Poseidon2Sampler.new(slotId, store, builder).tryGet

    let params = CircomCompatParams.init(r1cs, wasm, zkey)
    circom = CircomCompat.init(params)
    challenge = 1234567.toF.toBytes.toArray32

    proofInputs = (await sampler.getProofInput(challenge, samples)).tryGet

  teardown:
    circom.release()  # this comes from the rust FFI

  test "Should verify with correct input":
    var
      proof = circom.prove(proofInputs).tryGet

    check circom.verify(proof, proofInputs).tryGet

  test "Should not verify with incorrect input":
    proofInputs.slotIndex = 1 # change slot index

    let
      proof = circom.prove(proofInputs).tryGet

    check circom.verify(proof, proofInputs).tryGet == false
