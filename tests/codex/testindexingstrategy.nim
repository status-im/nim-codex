import std/sequtils
import pkg/chronos

import pkg/codex/utils/asynciter

import ../asynctest
import ./helpers

import pkg/codex/indexingstrategy

for offset in @[0, 1, 2, 100]:
  suite "Indexing strategies (Offset: " & $offset & ")":
    let
      firstIndex = 0 + offset
      lastIndex = 12 + offset
      nIters = 3
      linear = LinearStrategy.init(firstIndex, lastIndex, nIters)
      stepped = SteppedStrategy.init(firstIndex, lastIndex, nIters)

    test "linear":
      check:
        toSeq(linear.getIndicies(0)) == @[0, 1, 2, 3, 4].mapIt(it + offset)
        toSeq(linear.getIndicies(1)) == @[5, 6, 7, 8, 9].mapIt(it + offset)
        toSeq(linear.getIndicies(2)) == @[10, 11, 12].mapIt(it + offset)

    test "stepped":
      check:
        toSeq(stepped.getIndicies(0)) == @[0, 3, 6, 9, 12].mapIt(it + offset)
        toSeq(stepped.getIndicies(1)) == @[1, 4, 7, 10].mapIt(it + offset)
        toSeq(stepped.getIndicies(2)) == @[2, 5, 8, 11].mapIt(it + offset)

suite "Indexing strategies":
  let
    linear = LinearStrategy.init(0, 10, 3)
    stepped = SteppedStrategy.init(0, 10, 3)

  test "smallest range 0":
    let
      l = LinearStrategy.init(0, 0, 1)
      s = SteppedStrategy.init(0, 0, 1)
    check:
      toSeq(l.getIndicies(0)) == @[0]
      toSeq(s.getIndicies(0)) == @[0]

  test "smallest range 1":
    let
      l = LinearStrategy.init(0, 1, 1)
      s = SteppedStrategy.init(0, 1, 1)
    check:
      toSeq(l.getIndicies(0)) == @[0, 1]
      toSeq(s.getIndicies(0)) == @[0, 1]

  test "first index must be smaller than last index":
    expect IndexingWrongIndexError:
      discard LinearStrategy.init(10, 0, 1)

  test "iterations must be greater than zero":
    expect IndexingWrongIterationsError:
      discard LinearStrategy.init(0, 10, 0)

  test "should split elements evenly when possible":
    let
      l = LinearStrategy.init(0, 11, 3)
    check:
      toSeq(l.getIndicies(0)) == @[0, 1, 2, 3].mapIt(it)
      toSeq(l.getIndicies(1)) == @[4, 5, 6, 7].mapIt(it)
      toSeq(l.getIndicies(2)) == @[8, 9, 10, 11].mapIt(it)

  test "linear - oob":
    expect IndexingError:
      discard linear.getIndicies(3)

  test "stepped - oob":
    expect IndexingError:
      discard stepped.getIndicies(3)
