## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# TODO: This is super inneficient and needs a rewrite, but it'll do for now

{.push raises: [Defect].}

import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p except shuffle
import pkg/chronicles

import ./rng
import ./blocktype
import ./utils/asyncfutures

export blocktype

const
  DefaultChunkSize*: int64 = 1024 * 256

type
  # default reader type
  ChunkBuffer* = ptr UncheckedArray[byte]
  Reader* =
    proc(data: ChunkBuffer, len: int): Future[int] {.gcsafe, raises: [Defect].}

  ChunkerType* {.pure.} = enum
    FixedChunker
    RabinChunker

  Chunker* = ref object of RootObj
    reader*: Reader
    case kind*: ChunkerType:
    of FixedChunker:
      chunkSize*: Natural
      pad*: bool # pad last block if less than size
    of RabinChunker:
      discard

  FileChunker* = Chunker
  LPStreamChunker* = Chunker
  RandomChunker* = Chunker

proc getBytes*(c: Chunker): Future[seq[byte]] {.async.} =
  ## returns a chunk of bytes from
  ## the instantiated chunker
  ##

  var buff = newSeq[byte](c.chunkSize)
  let read = await c.reader(cast[ChunkBuffer](addr buff[0]), buff.len)

  if read <= 0:
    return @[]

  if not c.pad and buff.len != read:
    buff.setLen(read)

  return buff

func new*(
  T: type Chunker,
  kind = ChunkerType.FixedChunker,
  reader: Reader,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  var chunker = Chunker(
    kind: kind,
    reader: reader)

  if kind == ChunkerType.FixedChunker:
    chunker.pad = pad
    chunker.chunkSize = chunkSize

  return chunker

proc new*(
  T: type RandomChunker,
  rng: Rng,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  size: int,
  pad = false): T =
  ## create a chunker that produces
  ## random data
  ##

  var consumed = 0
  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.async, gcsafe, raises: [Defect].} =
    var alpha = toSeq(byte('A')..byte('z'))

    if consumed >= size:
      return 0

    var read = 0
    while read < len:
      rng.shuffle(alpha)
      for a in alpha:
        if read >= len:
          break

        data[read] = a
        read.inc

    consumed += read
    return read

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)

proc new*(
  T: type LPStreamChunker,
  stream: LPStream,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  ## create the default File chunker
  ##

  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.gcsafe, async, raises: [Defect].} =
    var res = 0
    try:
      while res < len:
        res += await stream.readOnce(data, len - res)
    except LPStreamEOFError as exc:
      trace "LPStreamChunker stream Eof", exc = exc.msg
    except CatchableError as exc:
      trace "CatchableError exception", exc = exc.msg
      raise newException(Defect, exc.msg)

    return res

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)

proc new*(
  T: type FileChunker,
  file: File,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  pad = false): T =
  ## create the default File chunker
  ##

  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.gcsafe, async, raises: [Defect].} =
    try:
      return file.readBuffer(addr data[0], len)
    except IOError as exc:
      # TODO: revisit error handling - should this be fatal?
      raise newException(Defect, exc.msg)

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)
