import std/sugar

import pkg/questionable
import pkg/chronos
import pkg/codex/utils/iter

import ../../asynctest
import ../helpers

checksuite "Test Iter":

  test "Should be finished":
    let iter = Iter[int].empty()

    check:
      iter.finished == true

  test "Should be iterable with `items`":
    let iter = Iter.new(0..<5)

    let items =
      collect:
        for v in iter:
          v

    check:
      items == @[0, 1, 2, 3, 4]

  test "Should be iterable with `pairs`":
    let iter = Iter.new(0..<5)

    let pairs =
      collect:
        for i, v in iter:
          (i, v)

    check:
      pairs == @[(0, 0), (1, 1), (2, 2), (3, 3), (4, 4)]

  test "Should map each item using `map`":
    let iter = Iter.new(0..<5)
      .map((i: int) => $i)

    check:
      iter.toSeq() == @["0", "1", "2", "3", "4"]

  test "Should leave only odd items using `filter`":
    let iter = Iter.new(0..<5)
      .filter((i: int) => (i mod 2) == 1)

    check:
      iter.toSeq() == @[1, 3]

  test "Should leave only odd items using `mapFilter`":
    let
      iter1 = Iter.new(0..<5)
      iter2 = mapFilter[int, string](iter1,
        proc(i: int): ?string =
          if (i mod 2) == 1:
            some($i)
          else:
            string.none
      )

    check:
      iter2.toSeq() == @["1", "3"]

  test "Should yield all items before err using `map`":
    let
      iter = Iter.new(0..<5)
       .map(
          proc (i: int): string =
            if i < 3:
              return $i
            else:
              raise newException(CatchableError, "Some error")
        )

    var collected: seq[string]

    expect CatchableError:
      for i in iter:
        collected.add(i)

    check:
      collected == @["0", "1", "2"]
      iter.finished

  test "Should yield all items before err using `filter`":
    let
      iter = Iter.new(0..<5)
       .filter(
          proc (i: int): bool =
            if i < 3:
              return true
            else:
              raise newException(CatchableError, "Some error")
        )

    var collected: seq[int]

    expect CatchableError:
      for i in iter:
        collected.add(i)

    check:
      collected == @[0, 1, 2]
      iter.finished

  test "Should yield all items before err using `mapFilter`":
    let
      iter1 = Iter.new(0..<5)
      iter2 = mapFilter[int, string](iter1,
          proc (i: int): ?string =
            if i < 3:
              return some($i)
            else:
              raise newException(CatchableError, "Some error")
        )

    var collected: seq[string]

    expect CatchableError:
      for i in iter2:
        collected.add(i)

    check:
      collected == @["0", "1", "2"]
      iter2.finished
