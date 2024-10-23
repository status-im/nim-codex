import std/sequtils
import std/sugar
import std/math

import ../../asynctest

import pkg/chronos
import pkg/libp2p/cid
import pkg/datastore

import pkg/codex/merkletree
import pkg/codex/rng
import pkg/codex/manifest
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/slots
import pkg/codex/stores
import pkg/codex/conf
import pkg/confutils/defs
import pkg/poseidon2/io
import pkg/codex/utils/poseidon2digest

import ./helpers
import ../helpers
import ./backends/helpers

suite "Test Prover":
  let
    samples = 5
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()
    challenge = 1234567.toF.toBytes.toArray32

  var
    store: BlockStore
    prover: Prover

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: ValidIpAddress.init("127.0.0.1"),
        discoveryIp: ValidIpAddress.init(IPv4_any()),
        metricsAddress: ValidIpAddress.init("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
        circomWasm: InputFile("tests/circuits/fixtures/proof_main.wasm"),
        circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey"),
        numProofSamples: samples
      )
      backend = config.initializeBackend().tryGet()

    store = RepoStore.new(repoDs, metaDs)
    prover = Prover.new(store, backend, config.numProofSamples)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  test "Should sample and prove a slot":
    let
      (_, _, verifiable) =
        await createVerifiableManifest(
          store,
          8, # number of blocks in the original dataset (before EC)
          5, # ecK
          3, # ecM
          blockSize,
          cellSize)

    let
      (inputs, proof) = (
        await prover.prove(1, verifiable, challenge)).tryGet

    check:
      (await prover.verify(proof, inputs)).tryGet == true

  test "Should generate valid proofs when slots consist of single blocks":

    # To get single-block slots, we just need to set the number of blocks in
    # the original dataset to be the same as ecK. The total number of blocks
    # after generating random data for parity will be ecK + ecM, which will
    # match the number of slots.
    let
      (_, _, verifiable) =
        await createVerifiableManifest(
          store,
          2, # number of blocks in the original dataset (before EC)
          2, # ecK
          1, # ecM
          blockSize,
          cellSize)

    let
      (inputs, proof) = (
        await prover.prove(1, verifiable, challenge)).tryGet

    check:
      (await prover.verify(proof, inputs)).tryGet == true
