## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p/stream/lpstream
import pkg/chronos

import ../logutils

export lpstream, chronos, logutils

logScope:
  topics = "codex seekablestream"

type SeekableStream* = ref object of LPStream
  offset*: int

method `size`*(self: SeekableStream): int {.base.} =
  raiseAssert("method unimplemented")

proc setPos*(self: SeekableStream, pos: int) =
  self.offset = pos
