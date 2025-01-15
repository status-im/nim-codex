import std/sugar

import pkg/questionable
import pkg/chronos

import ./iter

export iter

## AsyncIter[T] is similar to `Iter[Future[T]]` with addition of methods specific to asynchronous processing
##

type AsyncIter*[T] = ref object
  finished: bool
  next*: GenNext[Future[T]]

proc finish*[T](self: AsyncIter[T]): void =
  self.finished = true

proc finished*[T](self: AsyncIter[T]): bool =
  self.finished

iterator items*[T](self: AsyncIter[T]): Future[T] =
  while not self.finished:
    yield self.next()

iterator pairs*[T](self: AsyncIter[T]): tuple[key: int, val: Future[T]] {.inline.} =
  var i = 0
  while not self.finished:
    yield (i, self.next())
    inc(i)

proc map*[T, U](fut: Future[T], fn: Function[T, U]): Future[U] {.async.} =
  let t = await fut
  fn(t)

proc flatMap*[T, U](fut: Future[T], fn: Function[T, Future[U]]): Future[U] {.async.} =
  let t = await fut
  await fn(t)

proc new*[T](
    _: type AsyncIter[T],
    genNext: GenNext[Future[T]],
    isFinished: IsFinished,
    finishOnErr: bool = true,
): AsyncIter[T] =
  ## Creates a new Iter using elements returned by supplier function `genNext`.
  ## Iter is finished whenever `isFinished` returns true.
  ##

  var iter = AsyncIter[T]()

  proc next(): Future[T] {.async.} =
    if not iter.finished:
      var item: T
      try:
        item = await genNext()
      except CancelledError as err:
        iter.finish
        raise err
      except CatchableError as err:
        if finishOnErr or isFinished():
          iter.finish
        raise err

      if isFinished():
        iter.finish
      return item
    else:
      raise newException(
        CatchableError, "AsyncIter is finished but next item was requested"
      )

  if isFinished():
    iter.finish

  iter.next = next
  return iter

proc mapAsync*[T, U](iter: Iter[T], fn: Function[T, Future[U]]): AsyncIter[U] =
  AsyncIter[U].new(genNext = () => fn(iter.next()), isFinished = () => iter.finished())

proc new*[U, V: Ordinal](_: type AsyncIter[U], slice: HSlice[U, V]): AsyncIter[U] =
  ## Creates new Iter from a slice
  ##

  let iter = Iter[U].new(slice)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[U] {.async.} =
      i,
  )

proc new*[U, V, S: Ordinal](
    _: type AsyncIter[U], a: U, b: V, step: S = 1
): AsyncIter[U] =
  ## Creates new Iter in range a..b with specified step (default 1)
  ##

  let iter = Iter[U].new(a, b, step)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[U] {.async.} =
      i,
  )

proc empty*[T](_: type AsyncIter[T]): AsyncIter[T] =
  ## Creates an empty AsyncIter
  ##

  proc genNext(): Future[T] {.raises: [CatchableError].} =
    raise newException(CatchableError, "Next item requested from an empty AsyncIter")

  proc isFinished(): bool =
    true

  AsyncIter[T].new(genNext, isFinished)

proc map*[T, U](iter: AsyncIter[T], fn: Function[T, Future[U]]): AsyncIter[U] =
  AsyncIter[U].new(
    genNext = () => iter.next().flatMap(fn), isFinished = () => iter.finished
  )

proc mapFilter*[T, U](
    iter: AsyncIter[T], mapPredicate: Function[T, Future[Option[U]]]
): Future[AsyncIter[U]] {.async.} =
  var nextFutU: Option[Future[U]]

  proc tryFetch(): Future[void] {.async.} =
    nextFutU = Future[U].none
    while not iter.finished:
      let futT = iter.next()
      try:
        if u =? await futT.flatMap(mapPredicate):
          let futU = newFuture[U]("AsyncIter.mapFilterAsync")
          futU.complete(u)
          nextFutU = some(futU)
          break
      except CancelledError as err:
        raise err
      except CatchableError as err:
        let errFut = newFuture[U]("AsyncIter.mapFilterAsync")
        errFut.fail(err)
        nextFutU = some(errFut)
        break

  proc genNext(): Future[U] {.async.} =
    let futU = nextFutU.unsafeGet
    await tryFetch()
    await futU

  proc isFinished(): bool =
    nextFutU.isNone

  await tryFetch()
  AsyncIter[U].new(genNext, isFinished)

proc filter*[T](
    iter: AsyncIter[T], predicate: Function[T, Future[bool]]
): Future[AsyncIter[T]] {.async.} =
  proc wrappedPredicate(t: T): Future[Option[T]] {.async.} =
    if await predicate(t):
      some(t)
    else:
      T.none

  await mapFilter[T, T](iter, wrappedPredicate)

proc delayBy*[T](iter: AsyncIter[T], d: Duration): AsyncIter[T] =
  ## Delays emitting each item by given duration
  ##

  map[T, T](
    iter,
    proc(t: T): Future[T] {.async.} =
      await sleepAsync(d)
      t,
  )
