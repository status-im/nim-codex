## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/bitops

import pkg/questionable/results
import pkg/constantine/math/arithmetic

import ../../merkletree

func extractLowBits*[n: static int](elm: BigInt[n], k: int): uint64 =
  doAssert( k > 0 and k <= 64 )
  var r  = 0'u64
  for i in 0..<k:
    let b = bit[n](elm, i)
    let y = uint64(b)
    if (y != 0):
      r = bitor( r, 1'u64 shl i )
  r

func extractLowBits(fld: Poseidon2Hash, k: int): uint64 =
  let elm : BigInt[254] = fld.toBig()
  return extractLowBits(elm, k);

func floorLog2*(x : int) : int =
  doAssert ( x > 0 )
  var k = -1
  var y = x
  while (y > 0):
    k += 1
    y = y shr 1
  return k

func ceilingLog2*(x : int) : int =
  doAssert ( x > 0 )
  return (floorLog2(x - 1) + 1)

func toBlkInSlot*(cell: Natural, numCells: Natural): Natural =
  let log2 = ceilingLog2(numCells)
  doAssert( 1 shl log2 == numCells , "`numCells` is assumed to be a power of two" )

  return cell div numCells

func toCellInBlk*(cell: Natural, numCells: Natural): Natural =
  let log2 = ceilingLog2(numCells)
  doAssert( 1 shl log2 == numCells , "`numCells` is assumed to be a power of two" )

  return cell mod numCells

func cellIndex*(
  entropy: Poseidon2Hash,
  slotRoot: Poseidon2Hash,
  numCells: Natural, counter: Natural): Natural =
  let log2 = ceilingLog2(numCells)
  doAssert( 1 shl log2 == numCells , "`numCells` is assumed to be a power of two" )

  let hash = Sponge.digest( @[ entropy, slotRoot, counter.toF ], rate = 2 )
  return int( extractLowBits(hash, log2) )

func cellIndices*(
  entropy: Poseidon2Hash,
  slotRoot: Poseidon2Hash,
  numCells: Natural, nSamples: Natural): seq[Natural] =

  var indices: seq[Natural]
  for i in 1..nSamples:
    indices.add(cellIndex(entropy, slotRoot, numCells, i))

  indices
