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

import ./backend
import ../errors
import ../logutils

logScope:
  topics = "codex asyncerasure"

const
  CompletitionTimeout = 1.seconds
    # Maximum await time for completition after receiving a signal
  CompletitionRetryDelay = 10.millis

type
  EncoderBackendPtr = ptr EncoderBackend
  DecoderBackendPtr = ptr DecoderBackend

  # Args objects are missing seq[seq[byte]] field, to avoid unnecessary data copy
  EncodeTaskArgs = object
    signal: ThreadSignalPtr
    backend: EncoderBackendPtr
    blockSize: int
    ecM: int

  DecodeTaskArgs = object
    signal: ThreadSignalPtr
    backend: DecoderBackendPtr
    blockSize: int
    ecK: int

  SharedArrayHolder*[T] = object
    data: ptr UncheckedArray[T]
    size: int

  EncodeTaskResult = Result[SharedArrayHolder[byte], cstring]
  DecodeTaskResult = Result[SharedArrayHolder[byte], cstring]

proc encodeTask(args: EncodeTaskArgs, data: seq[seq[byte]]): EncodeTaskResult =
  var
    data = data.unsafeAddr
    parity = newSeqWith[seq[byte]](args.ecM, newSeq[byte](args.blockSize))

  try:
    let res = args.backend[].encode(data[], parity)

    if res.isOk:
      let
        resDataSize = parity.len * args.blockSize
        resData = cast[ptr UncheckedArray[byte]](allocShared0(resDataSize))
        arrHolder = SharedArrayHolder[byte](data: resData, size: resDataSize)

      for i in 0 ..< parity.len:
        copyMem(addr resData[i * args.blockSize], addr parity[i][0], args.blockSize)

      return ok(arrHolder)
    else:
      return err(res.error)
  except CatchableError as exception:
    return err(exception.msg.cstring)
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal", msg = err.msg

proc decodeTask(
    args: DecodeTaskArgs, data: seq[seq[byte]], parity: seq[seq[byte]]
): DecodeTaskResult =
  var
    data = data.unsafeAddr
    parity = parity.unsafeAddr
    recovered = newSeqWith[seq[byte]](args.ecK, newSeq[byte](args.blockSize))

  try:
    let res = args.backend[].decode(data[], parity[], recovered)

    if res.isOk:
      let
        resDataSize = recovered.len * args.blockSize
        resData = cast[ptr UncheckedArray[byte]](allocShared0(resDataSize))
        arrHolder = SharedArrayHolder[byte](data: resData, size: resDataSize)

      for i in 0 ..< recovered.len:
        copyMem(addr resData[i * args.blockSize], addr recovered[i][0], args.blockSize)

      return ok(arrHolder)
    else:
      return err(res.error)
  except CatchableError as exception:
    return err(exception.msg.cstring)
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal", msg = err.msg

proc proxySpawnEncodeTask(
    tp: Taskpool, args: EncodeTaskArgs, data: ref seq[seq[byte]]
): Flowvar[EncodeTaskResult] =
  # FIXME Uncomment the code below after addressing an issue:
  # https://github.com/codex-storage/nim-codex/issues/854

  # tp.spawn encodeTask(args, data[])

  let fv = EncodeTaskResult.newFlowVar
  fv.readyWith(encodeTask(args, data[]))
  return fv

proc proxySpawnDecodeTask(
    tp: Taskpool,
    args: DecodeTaskArgs,
    data: ref seq[seq[byte]],
    parity: ref seq[seq[byte]],
): Flowvar[DecodeTaskResult] =
  # FIXME Uncomment the code below after addressing an issue:
  # https://github.com/codex-storage/nim-codex/issues/854

  # tp.spawn decodeTask(args, data[], parity[])

  let fv = DecodeTaskResult.newFlowVar
  fv.readyWith(decodeTask(args, data[], parity[]))
  return fv

proc awaitResult[T](
    signal: ThreadSignalPtr, handle: Flowvar[T]
): Future[?!T] {.async.} =
  await wait(signal)

  var
    res: T
    awaitTotal: Duration
  while awaitTotal < CompletitionTimeout:
    if handle.tryComplete(res):
      return success(res)
    else:
      awaitTotal += CompletitionRetryDelay
      await sleepAsync(CompletitionRetryDelay)

  return failure(
    "Task signaled finish but didn't return any result within " & $CompletitionRetryDelay
  )

proc asyncEncode*(
    tp: Taskpool,
    backend: EncoderBackend,
    data: ref seq[seq[byte]],
    blockSize: int,
    ecM: int,
): Future[?!ref seq[seq[byte]]] {.async.} =
  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  try:
    let
      blockSize = data[0].len
      args = EncodeTaskArgs(
        signal: signal, backend: unsafeAddr backend, blockSize: blockSize, ecM: ecM
      )
      handle = proxySpawnEncodeTask(tp, args, data)

    without res =? await awaitResult(signal, handle), err:
      return failure(err)

    if res.isOk:
      var parity = seq[seq[byte]].new()
      parity[].setLen(ecM)

      for i in 0 ..< parity[].len:
        parity[i] = newSeq[byte](blockSize)
        copyMem(addr parity[i][0], addr res.value.data[i * blockSize], blockSize)

      deallocShared(res.value.data)

      return success(parity)
    else:
      return failure($res.error)
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg

proc asyncDecode*(
    tp: Taskpool,
    backend: DecoderBackend,
    data, parity: ref seq[seq[byte]],
    blockSize: int,
): Future[?!ref seq[seq[byte]]] {.async.} =
  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  try:
    let
      ecK = data[].len
      args = DecodeTaskArgs(
        signal: signal, backend: unsafeAddr backend, blockSize: blockSize, ecK: ecK
      )
      handle = proxySpawnDecodeTask(tp, args, data, parity)

    without res =? await awaitResult(signal, handle), err:
      return failure(err)

    if res.isOk:
      var recovered = seq[seq[byte]].new()
      recovered[].setLen(ecK)

      for i in 0 ..< recovered[].len:
        recovered[i] = newSeq[byte](blockSize)
        copyMem(addr recovered[i][0], addr res.value.data[i * blockSize], blockSize)

      deallocShared(res.value.data)

      return success(recovered)
    else:
      return failure($res.error)
  finally:
    if err =? signal.close().mapFailure.errorOption():
      error "Error closing signal", msg = $err.msg
