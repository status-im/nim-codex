import std/tables
import pkg/chronos

import ../logutils

{.push raises: [].}

type TrackedFutures* = ref object
  futures: Table[uint, FutureBase]
  cancelling: bool

logScope:
  topics = "trackable futures"

proc len*(self: TrackedFutures): int =
  self.futures.len

proc removeFuture(self: TrackedFutures, future: FutureBase) =
  if not self.cancelling and not future.isNil:
    self.futures.del(future.id)

proc track*[T](self: TrackedFutures, fut: Future[T]) =
  if self.cancelling:
    return

  self.futures[fut.id] = FutureBase(fut)

  proc cb(udata: pointer) =
    self.removeFuture(fut)

  fut.addCallback(cb)

proc cancelTracked*(self: TrackedFutures) {.async: (raises: []).} =
  self.cancelling = true

  trace "cancelling tracked futures"

  var cancellations: seq[FutureBase]
  for future in self.futures.values:
    if not future.isNil and not future.finished:
      cancellations.add future.cancelAndWait()

  await noCancel allFutures cancellations

  self.futures.clear()
  self.cancelling = false
