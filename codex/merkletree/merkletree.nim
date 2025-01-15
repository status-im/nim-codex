## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/bitops

import pkg/questionable/results

import ../errors

type
  CompressFn*[H, K] = proc(x, y: H, key: K): ?!H {.noSideEffect, raises: [].}

  MerkleTree*[H, K] = ref object of RootObj
    layers*: seq[seq[H]]
    compress*: CompressFn[H, K]
    zero*: H

  MerkleProof*[H, K] = ref object of RootObj
    index*: int # linear index of the leaf, starting from 0
    path*: seq[H] # order: from the bottom to the top
    nleaves*: int # number of leaves in the tree (=size of input)
    compress*: CompressFn[H, K] # compress function
    zero*: H # zero value

func depth*[H, K](self: MerkleTree[H, K]): int =
  return self.layers.len - 1

func leavesCount*[H, K](self: MerkleTree[H, K]): int =
  return self.layers[0].len

func levels*[H, K](self: MerkleTree[H, K]): int =
  return self.layers.len

func leaves*[H, K](self: MerkleTree[H, K]): seq[H] =
  return self.layers[0]

iterator layers*[H, K](self: MerkleTree[H, K]): seq[H] =
  for layer in self.layers:
    yield layer

iterator nodes*[H, K](self: MerkleTree[H, K]): H =
  for layer in self.layers:
    for node in layer:
      yield node

func root*[H, K](self: MerkleTree[H, K]): ?!H =
  let last = self.layers[^1]
  if last.len != 1:
    return failure "invalid tree"

  return success last[0]

func getProof*[H, K](
    self: MerkleTree[H, K], index: int, proof: MerkleProof[H, K]
): ?!void =
  let depth = self.depth
  let nleaves = self.leavesCount

  if not (index >= 0 and index < nleaves):
    return failure "index out of bounds"

  var path: seq[H] = newSeq[H](depth)
  var k = index
  var m = nleaves
  for i in 0 ..< depth:
    let j = k xor 1
    path[i] =
      if (j < m):
        self.layers[i][j]
      else:
        self.zero
    k = k shr 1
    m = (m + 1) shr 1

  proof.index = index
  proof.path = path
  proof.nleaves = nleaves
  proof.compress = self.compress

  success()

func getProof*[H, K](self: MerkleTree[H, K], index: int): ?!MerkleProof[H, K] =
  var proof = MerkleProof[H, K]()

  ?self.getProof(index, proof)

  success proof

func reconstructRoot*[H, K](proof: MerkleProof[H, K], leaf: H): ?!H =
  var
    m = proof.nleaves
    j = proof.index
    h = leaf
    bottomFlag = K.KeyBottomLayer

  for p in proof.path:
    let oddIndex: bool = (bitand(j, 1) != 0)
    if oddIndex:
      # the index of the child is odd, so the node itself can't be odd (a bit counterintuitive, yeah :)
      h = ?proof.compress(p, h, bottomFlag)
    else:
      if j == m - 1:
        # single child => odd node
        h = ?proof.compress(h, p, K(bottomFlag.ord + 2))
      else:
        # even node
        h = ?proof.compress(h, p, bottomFlag)
    bottomFlag = K.KeyNone
    j = j shr 1
    m = (m + 1) shr 1

  return success h

func verify*[H, K](proof: MerkleProof[H, K], leaf: H, root: H): ?!bool =
  success bool(root == ?proof.reconstructRoot(leaf))

func merkleTreeWorker*[H, K](
    self: MerkleTree[H, K], xs: openArray[H], isBottomLayer: static bool
): ?!seq[seq[H]] =
  let a = low(xs)
  let b = high(xs)
  let m = b - a + 1

  when not isBottomLayer:
    if m == 1:
      return success @[@xs]

  let halfn: int = m div 2
  let n: int = 2 * halfn
  let isOdd: bool = (n != m)

  var ys: seq[H]
  if not isOdd:
    ys = newSeq[H](halfn)
  else:
    ys = newSeq[H](halfn + 1)

  for i in 0 ..< halfn:
    const key = when isBottomLayer: K.KeyBottomLayer else: K.KeyNone
    ys[i] = ?self.compress(xs[a + 2 * i], xs[a + 2 * i + 1], key = key)
  if isOdd:
    const key = when isBottomLayer: K.KeyOddAndBottomLayer else: K.KeyOdd
    ys[halfn] = ?self.compress(xs[n], self.zero, key = key)

  success @[@xs] & ?self.merkleTreeWorker(ys, isBottomLayer = false)
