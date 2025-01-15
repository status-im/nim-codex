import std/unittest

import pkg/questionable/results
import pkg/stew/byteutils

import pkg/codex/merkletree
import ./helpers

const data = [
  "00000000000000000000000000000001".toBytes,
  "00000000000000000000000000000002".toBytes,
  "00000000000000000000000000000003".toBytes,
  "00000000000000000000000000000004".toBytes,
  "00000000000000000000000000000005".toBytes,
  "00000000000000000000000000000006".toBytes,
  "00000000000000000000000000000007".toBytes,
  "00000000000000000000000000000008".toBytes,
  "00000000000000000000000000000009".toBytes, "00000000000000000000000000000010".toBytes,
]

checksuite "merkletree - coders":
  test "encoding and decoding a tree yields the same tree":
    let
      tree = CodexTree.init(Sha256HashCodec, data).tryGet()
      encodedBytes = tree.encode()
      decodedTree = CodexTree.decode(encodedBytes).tryGet()

    check:
      tree == decodedTree

  test "encoding and decoding a proof yields the same proof":
    let
      tree = CodexTree.init(Sha256HashCodec, data).tryGet()
      proof = tree.getProof(4).tryGet()

    check:
      proof.verify(tree.leaves[4], tree.root.tryGet).isOk

    let
      encodedBytes = proof.encode()
      decodedProof = CodexProof.decode(encodedBytes).tryGet()

    check:
      proof == decodedProof
