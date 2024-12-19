## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results
import pkg/leopard

import ./backend
import ../errors
import ../logutils

logScope:
  topics = "codex asyncerasure"

const
  CompletitionTimeout = 1.seconds # Maximum await time for completition after receiving a signal
  CompletitionRetryDelay = 10.millis

type
  EncoderBackendPtr = ptr EncoderBackend
  DecoderBackendPtr = ptr DecoderBackend
  DecoderPtr = ptr LeoDecoder
  EncoderPtr = ptr LeoEncoder

  # Args objects are missing seq[seq[byte]] field, to avoid unnecessary data copy
  EncodeTaskArgs = object
    signal: ThreadSignalPtr
    encoder: EncoderPtr

  DecodeTaskArgs = object
    signal: ThreadSignalPtr
    decoder: DecoderPtr

  SharedArrayHolder*[T] = object
    data: ptr UncheckedArray[T]
    size: int

  TaskResult = Result[void, cstring]

proc encodeTask(args: EncodeTaskArgs): TaskResult =
  try:
    return args.encoder[].encodePrepared()
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal", msg = err.msg

proc decodeTask(args: DecodeTaskArgs): TaskResult =
  try:
    return args.decoder[].decodePrepared()
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal", msg = err.msg

proc proxySpawnEncodeTask(
  tp: Taskpool,
  args: EncodeTaskArgs
): Flowvar[TaskResult] =
  tp.spawn encodeTask(args)

proc proxySpawnDecodeTask(
  tp: Taskpool,
  args: DecodeTaskArgs
): Flowvar[TaskResult] = 
  tp.spawn decodeTask(args)

proc awaitTaskResult(signal: ThreadSignalPtr, handle: Flowvar[TaskResult]): Future[?!void] {.async.} =
  await wait(signal)

  var
    res: TaskResult
    awaitTotal: Duration
  while awaitTotal < CompletitionTimeout:
    if handle.tryComplete(res):
      if res.isOk:
        return success()
      else:
        return failure($res.error)
    else:
      awaitTotal += CompletitionRetryDelay
      await sleepAsync(CompletitionRetryDelay)

  return failure("Task signaled finish but didn't return any result within " & $CompletitionRetryDelay)

proc asyncEncode*(
  tp: Taskpool,
  encoder: sink LeoEncoder,
  data: ref seq[seq[byte]],
  blockSize: int,
  ecM: int
): Future[?!ref seq[seq[byte]]] {.async.} =
  if ecM == 0:
    return success(seq[seq[byte]].new())

  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  try:
    if err =? encoder.prepareEncode(data[]).mapFailure.errorOption():
      return failure(err)

    let
      args = EncodeTaskArgs(signal: signal, encoder: addr encoder)
      handle = proxySpawnEncodeTask(tp, args)

    if err =? (await awaitTaskResult(signal, handle)).errorOption():
      return failure(err)
    
    var parity = seq[seq[byte]].new()
    parity[].setLen(ecM)

    for i in 0..<parity[].len:
      parity[i] = newSeq[byte](blockSize)

    if err =? encoder.readParity(parity[]).mapFailure.errorOption():
      return failure(err)

    return success(parity)
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg

proc asyncDecode*(
  tp: Taskpool,
  decoder: sink LeoDecoder,
  data, parity: ref seq[seq[byte]],
  blockSize: int
): Future[?!ref seq[seq[byte]]] {.async.} =
  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  try:
    if err =? decoder.prepareDecode(data[], parity[]).mapFailure.errorOption():
      return failure(err)

    let
      args = DecodeTaskArgs(signal: signal, decoder: addr decoder)
      handle = proxySpawnDecodeTask(tp, args)

    if err =? (await awaitTaskResult(signal, handle)).errorOption():
      return failure(err)

    var recovered = seq[seq[byte]].new()
    recovered[].setLen(data[].len)
    for i in 0..<recovered[].len:
      recovered[i] = newSeq[byte](blockSize)

    if err =? decoder.readDecoded(recovered[]).mapFailure.errorOption():
      return failure(err)

    return success(recovered)
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg
