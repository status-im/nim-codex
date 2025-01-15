## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options

import pkg/stew/results
import pkg/chronos
import pkg/questionable/results

export results

type
  CodexError* = object of CatchableError # base codex error
  CodexResult*[T] = Result[T, ref CodexError]

template mapFailure*[T, V, E](
    exp: Result[T, V], exc: typedesc[E]
): Result[T, ref CatchableError] =
  ## Convert `Result[T, E]` to `Result[E, ref CatchableError]`
  ##

  exp.mapErr(
    proc(e: V): ref CatchableError =
      (ref exc)(msg: $e)
  )

template mapFailure*[T, V](exp: Result[T, V]): Result[T, ref CatchableError] =
  mapFailure(exp, CodexError)

# TODO: using a template here, causes bad codegen
func toFailure*[T](exp: Option[T]): Result[T, ref CatchableError] {.inline.} =
  if exp.isSome:
    success exp.get
  else:
    T.failure("Option is None")

# allFuturesThrowing was moved to the tests in libp2p
proc allFuturesThrowing*[T](args: varargs[Future[T]]): Future[void] =
  var futs: seq[Future[T]]
  for fut in args:
    futs &= fut
  proc call() {.async.} =
    var first: ref CatchableError = nil
    futs = await allFinished(futs)
    for fut in futs:
      if fut.failed:
        let err = fut.readError()
        if err of Defect:
          raise err
        else:
          if err of CancelledError:
            raise err
          if isNil(first):
            first = err
    if not isNil(first):
      raise first

  return call()

proc allFutureResult*[T](fut: seq[Future[T]]): Future[?!void] {.async.} =
  try:
    await allFuturesThrowing(fut)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)

  return success()
