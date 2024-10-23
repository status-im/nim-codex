import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronicles
import pkg/datastore/typedds

import ../utils/asynciter

type KeyVal*[T] = tuple[key: Key, value: T]

proc toAsyncIter*[T](
  queryIter: QueryIter[T],
  finishOnErr: bool = true
  ): Future[?!AsyncIter[?!QueryResponse[T]]] {.async.} =
  ## Converts `QueryIter[T]` to `AsyncIter[?!QueryResponse[T]]` and automatically
  ## runs dispose whenever `QueryIter` finishes or whenever an error occurs (only
  ## if the flag finishOnErr is set to true)
  ##

  if queryIter.finished:
    trace "Disposing iterator"
    if error =? (await queryIter.dispose()).errorOption:
      return failure(error)
    return success(AsyncIter[?!QueryResponse[T]].empty())

  var errOccurred = false

  proc genNext: Future[?!QueryResponse[T]] {.async.} =
    let queryResOrErr = await queryIter.next()

    if queryResOrErr.isErr:
      errOccurred = true

    if queryIter.finished or (errOccurred and finishOnErr):
      trace "Disposing iterator"
      if error =? (await queryIter.dispose()).errorOption:
        return failure(error)

    return queryResOrErr

  proc isFinished(): bool =
    queryIter.finished or (errOccurred and finishOnErr)

  AsyncIter[?!QueryResponse[T]].new(genNext, isFinished).success

proc filterSuccess*[T](
  iter: AsyncIter[?!QueryResponse[T]]
  ): Future[AsyncIter[tuple[key: Key, value: T]]] {.async.} =
  ## Filters out any items that are not success

  proc mapping(resOrErr: ?!QueryResponse[T]): Future[?KeyVal[T]] {.async.} =
    without res =? resOrErr, error:
      error "Error occurred when getting QueryResponse", msg = error.msg
      return KeyVal[T].none

    without key =? res.key:
      warn "No key for a QueryResponse"
      return KeyVal[T].none

    without value =? res.value, error:
      error "Error occurred when getting a value from QueryResponse", msg = error.msg
      return KeyVal[T].none

    (key: key, value: value).some

  await mapFilter[?!QueryResponse[T], KeyVal[T]](iter, mapping)
