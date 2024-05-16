import std/sequtils

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results

import ../../types
import ../../../utils/asyncthreads

import ./circomcompat

const
  CompletionTimeout = 1.seconds
    # Maximum await time for completition after receiving a signal
  CompletionRetryDelay = 10.millis

type
  AsyncCircomCompat* = object
    params*: CircomCompatParams
    tp*: Taskpool

  # Args objects are missing seq[seq[byte]] field, to avoid unnecessary data copy
  ProveTaskArgs* = object
    signal: ThreadSignalPtr
    params: CircomCompatParams

var circomBackend {.threadvar.}: CircomCompat 

proc proveTask[H](
    args: ProveTaskArgs, data: ProofInputs[H]
): Result[CircomProof, string] =

  try:
    let res = circomBackend.prove(data)
    if res.isOk:
      return ok(res.get())
    else:
      return err(res.error().msg)
  except CatchableError as exception:
    return err(exception.msg)
  finally:
    if err =? args.signal.fireSync().mapFailure.errorOption():
      error "Error firing signal in proveTask ", msg = err.msg

proc prove*[H](
    self: AsyncCircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async.} =
  ## Generates proof using circom-compat asynchronously
  ##

  without signal =? ThreadSignalPtr.new().mapFailure, err:
    return failure(err)

  let args = ProveTaskArgs(signal: signal, params: self.params)
  let flowvar = self.tp.spawn proveTask(args, input)

  without res =? await awaitThreadResult(signal, flowvar), err:
    return failure(err)

proc verify*[H](
    self: AsyncCircomCompat, proof: CircomProof, inputs: ProofInputs[H]
): Future[?!bool] {.async.} =
  ## Verify a proof using a ctx
  ##
  discard

proc init*(_: type AsyncCircomCompat, params: CircomCompatParams): AsyncCircomCompat =
  ## Create a new async circom
  ##
  AsyncCircomCompat(params)
