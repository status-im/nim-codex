import std/sequtils

import pkg/chronos
import pkg/questionable/results
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/manifest
import pkg/poseidon2

import pkg/codex/slots
import pkg/codex/merkletree
import pkg/codex/indexingstrategy

import ../asynctest
import ./helpers
import ./examples

checksuite "Manifest":
  let
    manifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 100.MiBs
    )

    protectedManifest = Manifest.new(
      manifest = manifest,
      treeCid = Cid.example,
      datasetSize = 200.MiBs,
      eck = 2,
      ecM = 2,
      strategy = SteppedStrategy
    )

    leaves = [
      0.toF.Poseidon2Hash,
      1.toF.Poseidon2Hash,
      2.toF.Poseidon2Hash,
      3.toF.Poseidon2Hash]

    slotLeavesCids = leaves.toSlotCids().tryGet

    tree = Poseidon2Tree.init(leaves).tryGet
    verifyCid = tree.root.tryGet.toVerifyCid().tryGet

    verifiableManifest = Manifest.new(
      manifest = protectedManifest,
      verifyRoot = verifyCid,
      slotRoots = slotLeavesCids
    ).tryGet()

  proc encodeDecode(manifest: Manifest): Manifest =
    let e = manifest.encode().tryGet()
    Manifest.decode(e).tryGet()

  test "Should encode/decode to/from base manifest":
    check:
      encodeDecode(manifest) == manifest

  test "Should encode/decode large manifest":
    let large = Manifest.new(
      treeCid = Cid.example,
      blockSize = (64 * 1024).NBytes,
      datasetSize = (5 * 1024).MiBs
    )

    check:
      encodeDecode(large) == large

  test "Should encode/decode to/from protected manifest":
    check:
      encodeDecode(protectedManifest) == protectedManifest

  test "Should encode/decode to/from verifiable manifest":
    check:
      encodeDecode(verifiableManifest) == verifiableManifest


suite "Manifest - Attribute Inheritance":
  proc makeProtectedManifest(strategy: StrategyType): Manifest =
    Manifest.new(
      manifest = Manifest.new(
        treeCid = Cid.example,
        blockSize = 1.MiBs,
        datasetSize = 100.MiBs,
        filename = "codex.png".some,
        mimetype = "image/png".some
      ),
      treeCid = Cid.example,
      datasetSize = 200.MiBs,
      ecK = 1,
      ecM = 1,
      strategy = strategy
    )

  test "Should preserve interleaving strategy for protected manifest in verifiable manifest":
    var verifiable = Manifest.new(
      manifest = makeProtectedManifest(SteppedStrategy),
      verifyRoot = Cid.example,
      slotRoots = @[Cid.example, Cid.example]
    ).tryGet()

    check verifiable.protectedStrategy == SteppedStrategy

    verifiable = Manifest.new(
      manifest = makeProtectedManifest(LinearStrategy),
      verifyRoot = Cid.example,
      slotRoots = @[Cid.example, Cid.example]
    ).tryGet()

    check verifiable.protectedStrategy == LinearStrategy

  test "Should preserve metadata for manifest in verifiable manifest":
    var verifiable = Manifest.new(
      manifest = makeProtectedManifest(SteppedStrategy),
      verifyRoot = Cid.example,
      slotRoots = @[Cid.example, Cid.example]
    ).tryGet()

    check verifiable.filename.isSome == true
    check verifiable.filename.get() == "codex.png"
    check verifiable.mimetype.isSome == true
    check verifiable.mimetype.get() == "image/png"
