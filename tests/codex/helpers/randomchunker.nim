import std/sequtils

import pkg/chronos

import pkg/codex/chunker
import pkg/codex/rng

export chunker

type RandomChunker* = Chunker

proc new*(
    T: type RandomChunker,
    rng: Rng,
    chunkSize: int | NBytes,
    size: int | NBytes,
    pad = false,
): RandomChunker =
  ## Create a chunker that produces random data
  ##

  let
    size = size.int
    chunkSize = chunkSize.NBytes

  var consumed = 0
  proc reader(
      data: ChunkBuffer, len: int
  ): Future[int] {.async, gcsafe, raises: [Defect].} =
    var alpha = toSeq(byte('A') .. byte('z'))

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

  Chunker.new(reader = reader, pad = pad, chunkSize = chunkSize)
