import std/unittest

import pkg/codex/utils

suite "findIt":
  setup:
    type AnObject = object
      attribute1*: int

    var objList =
      @[
        AnObject(attribute1: 1),
        AnObject(attribute1: 3),
        AnObject(attribute1: 5),
        AnObject(attribute1: 3),
      ]

  test "should retur index of first object matching predicate":
    assert objList.findIt(it.attribute1 == 3) == 1

  test "should return -1 when no object matches predicate":
    assert objList.findIt(it.attribute1 == 15) == -1

suite "parseDuration":
  test "should parse durations":
    var res: Duration # caller must still know if 'b' refers to bytes|bits
    check parseDuration("10Hr", res) == 3
    check res == hours(10)
    check parseDuration("64min", res) == 3
    check res == minutes(64)
    check parseDuration("7m/block", res) == 2 # '/' stops parse
    check res == minutes(7) # 1 shl 30, forced binary metric
    check parseDuration("3d", res) == 2 # '/' stops parse
    check res == days(3) # 1 shl 30, forced binary metric
