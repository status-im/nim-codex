## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

import std/hashes
import std/strutils

import pkg/upraises

import ./logutils

type
  NBytes* = distinct Natural

template basicMaths(T: untyped) =
  proc `+` *(x: T, y: static[int]): T = T(`+`(x.Natural, y.Natural))
  proc `-` *(x: T, y: static[int]): T = T(`-`(x.Natural, y.Natural))
  proc `*` *(x: T, y: static[int]): T = T(`*`(x.Natural, y.Natural))
  proc `+` *(x, y: T): T = T(`+`(x.Natural, y.Natural))
  proc `-` *(x, y: T): T = T(`-`(x.Natural, y.Natural))
  proc `*` *(x, y: T): T = T(`*`(x.Natural, y.Natural))
  proc `<` *(x, y: T): bool {.borrow.}
  proc `<=` *(x, y: T): bool {.borrow.}
  proc `==` *(x, y: T): bool {.borrow.}
  proc `+=` *(x: var T, y: T) {.borrow.}
  proc `-=` *(x: var T, y: T) {.borrow.}
  proc `hash` *(x: T): Hash {.borrow.}

template divMaths(T: untyped) =
  proc `mod` *(x, y: T): T = T(`mod`(x.Natural, y.Natural))
  proc `div` *(x, y: T): Natural = `div`(x.Natural, y.Natural)
  # proc `/` *(x, y: T): Natural = `/`(x.Natural, y.Natural)

basicMaths(NBytes)
divMaths(NBytes)

proc `$`*(ts: NBytes): string = $(int(ts)) & "'NByte"
proc `'nb`*(n: string): NBytes = parseInt(n).NBytes

logutils.formatIt(NBytes): $it

const
  KiB = 1024.NBytes # ByteSz, 1 kibibyte = 1,024 ByteSz
  MiB = KiB * 1024  # ByteSz, 1 mebibyte = 1,048,576 ByteSz
  GiB = MiB * 1024  # ByteSz, 1 gibibyte = 1,073,741,824 ByteSz

proc KiBs*(v: Natural): NBytes = v.NBytes * KiB
proc MiBs*(v: Natural): NBytes = v.NBytes * MiB
proc GiBs*(v: Natural): NBytes = v.NBytes * GiB

func divUp*[T: NBytes](a, b : T): int =
  ## Division with result rounded up (rather than truncated as in 'div')
  assert(b != T(0))
  if a==T(0):  int(0) else: int( ((a - T(1)) div b) + 1 )

when isMainModule:

  import unittest2

  suite "maths":
    test "basics":
      let x = 5.NBytes
      let y = 10.NBytes
      check x + y == 15.NBytes
      expect RangeDefect:
        check x - y == 10.NBytes
      check y - x == 5.NBytes
      check x * y == 50.NBytes
      check y div x == 2
      check y > x == true
      check y <= x == false
