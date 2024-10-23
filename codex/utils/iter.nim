import std/sugar

import pkg/questionable
import pkg/questionable/results

type
  Function*[T, U] = proc(fut: T): U {.raises: [CatchableError], gcsafe, closure.}
  IsFinished* = proc(): bool {.raises: [], gcsafe, closure.}
  GenNext*[T] = proc(): T {.raises: [CatchableError], gcsafe.}
  Iter*[T] = ref object
    finished: bool
    next*: GenNext[T]

proc finish*[T](self: Iter[T]): void =
  self.finished = true

proc finished*[T](self: Iter[T]): bool =
  self.finished

iterator items*[T](self: Iter[T]): T =
  while not self.finished:
    yield self.next()

iterator pairs*[T](self: Iter[T]): tuple[key: int, val: T] {.inline.} =
  var i = 0
  while not self.finished:
    yield (i, self.next())
    inc(i)

proc new*[T](_: type Iter[T], genNext: GenNext[T], isFinished: IsFinished, finishOnErr: bool = true): Iter[T] =
  ## Creates a new Iter using elements returned by supplier function `genNext`.
  ## Iter is finished whenever `isFinished` returns true.
  ##

  var iter = Iter[T]()

  proc next(): T {.raises: [CatchableError].} =
    if not iter.finished:
      var item: T
      try:
        item = genNext()
      except CatchableError as err:
        if finishOnErr or isFinished():
          iter.finish
        raise err

      if isFinished():
        iter.finish
      return item
    else:
      raise newException(CatchableError, "Iter is finished but next item was requested")

  if isFinished():
    iter.finish

  iter.next = next
  return iter

proc new*[U, V, S: Ordinal](_: type Iter[U], a: U, b: V, step: S = 1): Iter[U] =
  ## Creates a new Iter in range a..b with specified step (default 1)
  ##

  var i = a

  proc genNext(): U =
    let u = i
    inc(i, step)
    u

  proc isFinished(): bool =
    (step > 0 and i > b) or
      (step < 0 and i < b)

  Iter[U].new(genNext, isFinished)

proc new*[U, V: Ordinal](_: type Iter[U], slice: HSlice[U, V]): Iter[U] =
  ## Creates a new Iter from a slice
  ##

  Iter[U].new(slice.a.int, slice.b.int, 1)

proc new*[T](_: type Iter[T], items: seq[T]): Iter[T] =
  ## Creates a new Iter from a sequence
  ##

  Iter[int].new(0..<items.len)
    .map((i: int) => items[i])

proc empty*[T](_: type Iter[T]): Iter[T] =
  ## Creates an empty Iter
  ##

  proc genNext(): T {.raises: [CatchableError].} =
    raise newException(CatchableError, "Next item requested from an empty Iter")
  proc isFinished(): bool = true

  Iter[T].new(genNext, isFinished)

proc map*[T, U](iter: Iter[T], fn: Function[T, U]): Iter[U] =
  Iter[U].new(
    genNext    = () => fn(iter.next()),
    isFinished = () => iter.finished
  )

proc mapFilter*[T, U](iter: Iter[T], mapPredicate: Function[T, Option[U]]): Iter[U] =
  var nextUOrErr: Option[Result[U, ref CatchableError]]

  proc tryFetch(): void =
    nextUOrErr = Result[U, ref CatchableError].none
    while not iter.finished:
      try:
        let t = iter.next()
        if u =? mapPredicate(t):
          nextUOrErr = some(success(u))
          break
      except CatchableError as err:
        nextUOrErr = some(U.failure(err))

  proc genNext(): U {.raises: [CatchableError].} =
    # at this point nextUOrErr should always be some(..)
    without u =? nextUOrErr.unsafeGet, err:
      raise err

    tryFetch()
    return u

  proc isFinished(): bool =
    nextUOrErr.isNone

  tryFetch()
  Iter[U].new(genNext, isFinished)

proc filter*[T](iter: Iter[T], predicate: Function[T, bool]): Iter[T] =
  proc wrappedPredicate(t: T): Option[T] =
    if predicate(t):
      some(t)
    else:
      T.none

  mapFilter[T, T](iter, wrappedPredicate)
