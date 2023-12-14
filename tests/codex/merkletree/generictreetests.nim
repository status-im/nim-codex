import std/unittest
import std/sequtils

import pkg/codex/merkletree

import ../helpers

proc checkGenericTree*[H, K, U](
  name: string,
  data: openArray[H],
  zero: H,
  compress: proc(z, y: H, key: K): H,
  makeTree: proc(data: seq[H]): U) =

  let
    data = @data

  checksuite "Correctness MerkleTree tests - " & name:

    test "Should build correct tree for even bottom layer":
      let
        expectedRoot = compress(
            compress(
              compress(data[0], data[1], K.KeyBottomLayer),
              compress(data[2], data[3], K.KeyBottomLayer),
              K.KeyNone
            ),
            compress(
              compress(data[4], data[5], K.KeyBottomLayer),
              compress(data[6], data[7], K.KeyBottomLayer),
              K.KeyNone
            ),
            K.KeyNone
          )

      let
        tree = makeTree( data[0..7] )

      check:
        tree.root == expectedRoot

    test "Should build correct tree for un-even bottom layer":
      let
        expectedRoot = compress(
            compress(
              compress(data[0], data[1], K.KeyBottomLayer),
              compress(data[2], data[3], K.KeyBottomLayer),
              K.KeyNone
            ),
            compress(
              compress(data[4], data[5], K.KeyBottomLayer),
              compress(data[6], zero, K.KeyOddAndBottomLayer),
              K.KeyNone
            ),
            K.KeyNone
          )

      let
        tree = makeTree( data[0..6] )

      check:
        tree.root == expectedRoot

    test "Should build correct tree for even bottom and uneven upper layers":
      let
        expectedRoot = compress(
          compress(
            compress(
              compress(data[0], data[1], K.KeyBottomLayer),
              compress(data[2], data[3], K.KeyBottomLayer),
              K.KeyNone
            ),
            compress(
              compress(data[4], data[5], K.KeyBottomLayer),
              compress(data[6], data[7], K.KeyBottomLayer),
              K.KeyNone
            ),
            K.KeyNone
          ),
          compress(
            compress(
              compress(data[8], data[9], K.KeyBottomLayer),
              zero,
              K.KeyOdd
            ),
            zero,
            K.KeyOdd
          ),
          K.KeyNone
        )

      let
        tree = makeTree( data[0..9] )

      check:
        tree.root == expectedRoot

    test "Should get and validate correct proofs":
      let
        expectedRoot = compress(
          compress(
            compress(
              compress(data[0], data[1], K.KeyBottomLayer),
              compress(data[2], data[3], K.KeyBottomLayer),
              K.KeyNone
            ),
            compress(
              compress(data[4], data[5], K.KeyBottomLayer),
              compress(data[6], data[7], K.KeyBottomLayer),
              K.KeyNone
            ),
            K.KeyNone
          ),
          compress(
            compress(
              compress(data[8], data[9], K.KeyBottomLayer),
              zero,
              K.KeyOdd
            ),
            zero,
            K.KeyOdd
          ),
          K.KeyNone
        )

      let
        tree = makeTree( data )

      for i in 0..<data.len:
        let proof = tree.getProof(i).tryGet
        check:
          proof.verify(expectedRoot).isOk
