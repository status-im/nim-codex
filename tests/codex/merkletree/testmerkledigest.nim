import std/unittest
import std/sequtils
import std/random

import pkg/poseidon2
import pkg/poseidon2/sponge

import pkg/questionable/results

import pkg/codex/merkletree
import pkg/codex/utils/poseidon2digest

import ./helpers

suite "Digest - MerkleTree":
  const KB = 1024

  test "Hashes chunks of data with sponge, and combines them in merkle root":
    let bytes = newSeqWith(64 * KB, rand(byte))
    var leaves: seq[Poseidon2Hash]
    for i in 0 ..< 32:
      let
        chunk = bytes[(i * 2 * KB) ..< ((i + 1) * 2 * KB)]
        digest = Sponge.digest(chunk, rate = 2)
      leaves.add(digest)

    let
      digest = Poseidon2Tree.digest(bytes, chunkSize = 2 * KB).tryGet
      spongeDigest = SpongeMerkle.digest(bytes, chunkSize = 2 * KB)
      codexPosTree = Poseidon2Tree.init(leaves).tryGet
      rootDigest = codexPosTree.root.tryGet

    check:
      bool(digest == spongeDigest)
      bool(digest == rootDigest)

  test "Handles partial chunk at the end":
    let bytes = newSeqWith(63 * KB, rand(byte))
    var leaves: seq[Poseidon2Hash]
    for i in 0 ..< 31:
      let
        chunk = bytes[(i * 2 * KB) ..< ((i + 1) * 2 * KB)]
        digest = Sponge.digest(chunk, rate = 2)
      leaves.add(digest)

    let partialChunk = bytes[(62 * KB) ..< (63 * KB)]
    leaves.add(Sponge.digest(partialChunk, rate = 2))

    let
      digest = Poseidon2Tree.digest(bytes, chunkSize = 2 * KB).tryGet
      spongeDigest = SpongeMerkle.digest(bytes, chunkSize = 2 * KB)
      codexPosTree = Poseidon2Tree.init(leaves).tryGet
      rootDigest = codexPosTree.root.tryGet

    check:
      bool(digest == spongeDigest)
      bool(digest == rootDigest)
