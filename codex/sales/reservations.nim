## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##
##                                                             +--------------------------------------+
##                                                             |            RESERVATION               |
## +--------------------------------------------+              |--------------------------------------|
## |            AVAILABILITY                    |              | ReservationId  | id             | PK |
## |--------------------------------------------|              |--------------------------------------|
## | AvailabilityId   | id                | PK  |<-||-------o<-| AvailabilityId | availabilityId | FK |
## |--------------------------------------------|              |--------------------------------------|
## | UInt256          | totalSize         |     |              | UInt256        | size           |    |
## |--------------------------------------------|              |--------------------------------------|
## | UInt256          | freeSize          |     |              | UInt256        | slotIndex      |    |
## |--------------------------------------------|              +--------------------------------------+
## | UInt256          | duration          |     |
## |--------------------------------------------|
## | UInt256          | minPricePerByte   |     |
## |--------------------------------------------|
## | UInt256          | totalCollateral   |     |
## +--------------------------------------------+

import pkg/upraises
push: {.upraises: [].}

import std/sequtils
import std/sugar
import std/typetraits
import std/sequtils
import pkg/chronos
import pkg/datastore
import pkg/nimcrypto
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/stew/byteutils
import ../codextypes
import ../logutils
import ../clock
import ../stores
import ../market
import ../contracts/requests
import ../utils/json
import ../units

export requests
export logutils

logScope:
  topics = "sales reservations"


type
  AvailabilityId* = distinct array[32, byte]
  ReservationId* = distinct array[32, byte]
  SomeStorableObject = Availability | Reservation
  SomeStorableId = AvailabilityId | ReservationId
  Availability* = ref object
    id* {.serialize.}: AvailabilityId
    totalSize* {.serialize.}: UInt256
    freeSize* {.serialize.}: UInt256
    duration* {.serialize.}: UInt256
    minPricePerByte* {.serialize.}: UInt256 
    totalCollateral* {.serialize.}: UInt256
  Reservation* = ref object
    id* {.serialize.}: ReservationId
    availabilityId* {.serialize.}: AvailabilityId
    size* {.serialize.}: UInt256
    requestId* {.serialize.}: RequestId
    slotIndex* {.serialize.}: UInt256
    collateralPerByte* {.serialize.}: UInt256
  Reservations* = ref object of RootObj
    availabilityLock: AsyncLock # Lock for protecting assertions of availability's sizes when searching for matching availability
    repo: RepoStore
    onAvailabilityAdded: ?OnAvailabilityAdded
  GetNext* = proc(): Future[?seq[byte]] {.upraises: [], gcsafe, closure.}
  IterDispose* = proc(): Future[?!void] {.gcsafe, closure.}
  OnAvailabilityAdded* = proc(availability: Availability): Future[void] {.upraises: [], gcsafe.}
  StorableIter* = ref object
    finished*: bool
    next*: GetNext
    dispose*: IterDispose
  ReservationsError* = object of CodexError
  ReserveFailedError* = object of ReservationsError
  ReleaseFailedError* = object of ReservationsError
  DeleteFailedError* = object of ReservationsError
  GetFailedError* = object of ReservationsError
  NotExistsError* = object of ReservationsError
  SerializationError* = object of ReservationsError
  UpdateFailedError* = object of ReservationsError
  BytesOutOfBoundsError* = object of ReservationsError

const
  SalesKey = (CodexMetaKey / "sales").tryGet # TODO: move to sales module
  ReservationsKey = (SalesKey / "reservations").tryGet

proc hash*(x: AvailabilityId): Hash {.borrow.}
proc all*(self: Reservations, T: type SomeStorableObject): Future[?!seq[T]] {.async.}

template withLock(lock, body) =
  try:
    await lock.acquire()
    body
  finally:
    if lock.locked:
      lock.release()


proc new*(T: type Reservations,
          repo: RepoStore): Reservations =

  T(availabilityLock: newAsyncLock(),repo: repo)

proc init*(
  _: type Availability,
  totalSize: UInt256,
  freeSize: UInt256,
  duration: UInt256,
  minPricePerByte: UInt256,
  totalCollateral: UInt256): Availability =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: AvailabilityId(id), totalSize:totalSize, freeSize: freeSize,
    duration: duration, minPricePerByte: minPricePerByte,
    totalCollateral: totalCollateral)

proc init*(
  _: type Reservation,
  availabilityId: AvailabilityId,
  size: UInt256,
  requestId: RequestId,
  slotIndex: UInt256,
  collateralPerByte: UInt256
): Reservation =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Reservation(id: ReservationId(id), availabilityId: availabilityId,
    size: size, requestId: requestId, slotIndex: slotIndex,
    collateralPerByte: collateralPerByte)

func toArray(id: SomeStorableId): array[32, byte] =
  array[32, byte](id)

proc `==`*(x, y: AvailabilityId): bool {.borrow.}
proc `==`*(x, y: ReservationId): bool {.borrow.}
proc `==`*(x, y: Reservation): bool =
  x.id == y.id
proc `==`*(x, y: Availability): bool =
  x.id == y.id

proc `$`*(id: SomeStorableId): string = id.toArray.toHex

proc toErr[E1: ref CatchableError, E2: ReservationsError](
  e1: E1,
  _: type E2,
  msg: string = e1.msg): ref E2 =

  return newException(E2, msg, e1)

logutils.formatIt(LogFormat.textLines, SomeStorableId): it.short0xHexLog
logutils.formatIt(LogFormat.json, SomeStorableId): it.to0xHexLog

proc `onAvailabilityAdded=`*(self: Reservations,
                            onAvailabilityAdded: OnAvailabilityAdded) =
  self.onAvailabilityAdded = some onAvailabilityAdded

func key*(id: AvailabilityId): ?!Key =
  ## sales / reservations / <availabilityId>
  (ReservationsKey / $id)

func key*(reservationId: ReservationId, availabilityId: AvailabilityId): ?!Key =
  ## sales / reservations / <availabilityId> / <reservationId>
  (availabilityId.key / $reservationId)

func key*(availability: Availability): ?!Key =
  return availability.id.key

func maxCollateralPerByte*(availability: Availability): UInt256 =
  return availability.totalCollateral / availability.freeSize

func key*(reservation: Reservation): ?!Key =
  return key(reservation.id, reservation.availabilityId)

func available*(self: Reservations): uint = self.repo.available.uint

func hasAvailable*(self: Reservations, bytes: uint): bool =
  self.repo.available(bytes.NBytes)

proc exists*(
  self: Reservations,
  key: Key): Future[bool] {.async.} =

  let exists = await self.repo.metaDs.ds.contains(key)
  return exists

proc getImpl(
  self: Reservations,
  key: Key): Future[?!seq[byte]] {.async.} =

  if not await self.exists(key):
    let err = newException(NotExistsError, "object with key " & $key & " does not exist")
    return failure(err)

  without serialized =? await self.repo.metaDs.ds.get(key), error:
    return failure(error.toErr(GetFailedError))

  return success serialized

proc get*(
  self: Reservations,
  key: Key,
  T: type SomeStorableObject): Future[?!T] {.async.} =

  without serialized =? await self.getImpl(key), error:
    return failure(error)

  without obj =? T.fromJson(serialized), error:
    return failure(error.toErr(SerializationError))

  return success obj

proc updateImpl(
  self: Reservations,
  obj: SomeStorableObject): Future[?!void] {.async.} =

  trace "updating " & $(obj.type), id = obj.id

  without key =? obj.key, error:
    return failure(error)

  if err =? (await self.repo.metaDs.ds.put(
    key,
    @(obj.toJson.toBytes)
  )).errorOption:
    return failure(err.toErr(UpdateFailedError))

  return success()

proc updateAvailability(
  self: Reservations,
  obj: Availability): Future[?!void] {.async.} =

  logScope:
    availabilityId = obj.id

  without key =? obj.key, error:
    return failure(error)

  without oldAvailability =? await self.get(key, Availability), err:
    if err of NotExistsError:
      trace "Creating new Availability"
      let res = await self.updateImpl(obj)
      # inform subscribers that Availability has been added
      if onAvailabilityAdded =? self.onAvailabilityAdded:
        # when chronos v4 is implemented, and OnAvailabilityAdded is annotated
        # with async:(raises:[]), we can remove this try/catch as we know, with
        # certainty, that nothing will be raised
        try:
          await onAvailabilityAdded(obj)
        except CancelledError as e:
          raise e
        except CatchableError as e:
          # we don't have any insight into types of exceptions that
          # `onAvailabilityAdded` can raise because it is caller-defined
          warn "Unknown error during 'onAvailabilityAdded' callback", error = e.msg
      return res
    else:
      return failure(err)

  # Sizing of the availability changed, we need to adjust the repo reservation accordingly
  if oldAvailability.totalSize != obj.totalSize:
    trace "totalSize changed, updating repo reservation"
    if oldAvailability.totalSize < obj.totalSize: # storage added
      if reserveErr =? (await self.repo.reserve((obj.totalSize - oldAvailability.totalSize).truncate(uint).NBytes)).errorOption:
        return failure(reserveErr.toErr(ReserveFailedError))

    elif oldAvailability.totalSize > obj.totalSize: # storage removed
      if reserveErr =? (await self.repo.release((oldAvailability.totalSize - obj.totalSize).truncate(uint).NBytes)).errorOption:
        return failure(reserveErr.toErr(ReleaseFailedError))

  let res = await self.updateImpl(obj)

  if oldAvailability.freeSize < obj.freeSize: # availability added
    # inform subscribers that Availability has been modified (with increased
    # size)
    if onAvailabilityAdded =? self.onAvailabilityAdded:
      # when chronos v4 is implemented, and OnAvailabilityAdded is annotated
      # with async:(raises:[]), we can remove this try/catch as we know, with
      # certainty, that nothing will be raised
      try:
        await onAvailabilityAdded(obj)
      except CancelledError as e:
        raise e
      except CatchableError as e:
        # we don't have any insight into types of exceptions that
        # `onAvailabilityAdded` can raise because it is caller-defined
        warn "Unknown error during 'onAvailabilityAdded' callback", error = e.msg

  return res

proc update*(
  self: Reservations,
  obj: Reservation): Future[?!void] {.async.} =
  return await self.updateImpl(obj)

proc update*(
  self: Reservations,
  obj: Availability): Future[?!void] {.async.} =
  withLock(self.availabilityLock):
    return await self.updateAvailability(obj)

proc delete(
  self: Reservations,
  key: Key): Future[?!void] {.async.} =

  trace "deleting object", key

  if not await self.exists(key):
    return success()

  if err =? (await self.repo.metaDs.ds.delete(key)).errorOption:
    return failure(err.toErr(DeleteFailedError))

  return success()

proc deleteReservation*(
  self: Reservations,
  reservationId: ReservationId,
  availabilityId: AvailabilityId): Future[?!void] {.async.} =

  logScope:
    reservationId
    availabilityId

  trace "deleting reservation"
  without key =? key(reservationId, availabilityId), error:
    return failure(error)

  withLock(self.availabilityLock):
    without reservation =? (await self.get(key, Reservation)), error:
      if error of NotExistsError:
        return success()
      else:
        return failure(error)

    if reservation.size > 0.u256:
      trace "returning remaining reservation bytes to availability",
        size = reservation.size

      without availabilityKey =? availabilityId.key, error:
        return failure(error)

      without var availability =? await self.get(availabilityKey, Availability), error:
        return failure(error)

      availability.freeSize += reservation.size

      # MC2: shall we return the collateral to the availability?
      availability.totalCollateral += reservation.size *
        reservation.collateralPerByte

      if updateErr =? (await self.updateAvailability(availability)).errorOption:
        return failure(updateErr)

    if err =? (await self.repo.metaDs.ds.delete(key)).errorOption:
      return failure(err.toErr(DeleteFailedError))

    return success()

# TODO: add support for deleting availabilities
# To delete, must not have any active sales.

proc createAvailability*(
  self: Reservations,
  size: UInt256,
  duration: UInt256,
  minPricePerByte: UInt256,
  totalCollateral: UInt256): Future[?!Availability] {.async.} =

  trace "creating availability", size, duration, minPricePerByte, totalCollateral

  let availability = Availability.init(
    size, size, duration, minPricePerByte, totalCollateral
  )
  let bytes = availability.freeSize.truncate(uint)

  if reserveErr =? (await self.repo.reserve(bytes.NBytes)).errorOption:
    return failure(reserveErr.toErr(ReserveFailedError))

  if updateErr =? (await self.update(availability)).errorOption:

    # rollback the reserve
    trace "rolling back reserve"
    if rollbackErr =? (await self.repo.release(bytes.NBytes)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  return success(availability)

method createReservation*(
  self: Reservations,
  availabilityId: AvailabilityId,
  slotSize: UInt256,
  requestId: RequestId,
  slotIndex: UInt256,
  collateralPerByte: UInt256
): Future[?!Reservation] {.async, base.} =

  withLock(self.availabilityLock):
    without availabilityKey =? availabilityId.key, error:
      return failure(error)

    without availability =? await self.get(availabilityKey, Availability), error:
      return failure(error)

    # Check that the found availability has enough free space after the lock has been acquired, to prevent asynchronous Availiability modifications
    if availability.freeSize < slotSize:
      let error = newException(
        BytesOutOfBoundsError,
        "trying to reserve an amount of bytes that is greater than the free size of the Availability")
      return failure(error)

    trace "Creating reservation", availabilityId, slotSize, requestId, slotIndex

    let reservation = Reservation.init(availabilityId, slotSize, requestId,
      slotIndex, collateralPerByte)

    if createResErr =? (await self.update(reservation)).errorOption:
      return failure(createResErr)

    # reduce availability freeSize by the slot size, which is now accounted for in
    # the newly created Reservation
    availability.freeSize -= slotSize

    # adjust the remaining totalCollateral
    availability.totalCollateral -= slotSize * collateralPerByte

    # update availability with reduced size
    trace "Updating availability with reduced size"
    if updateErr =? (await self.updateAvailability(availability)).errorOption:
      trace "Updating availability failed, rolling back reservation creation"

      without key =? reservation.key, keyError:
        keyError.parent = updateErr
        return failure(keyError)

      # rollback the reservation creation
      if rollbackErr =? (await self.delete(key)).errorOption:
        rollbackErr.parent = updateErr
        return failure(rollbackErr)

      return failure(updateErr)

    trace "Reservation succesfully created"
    return success(reservation)

proc returnBytesToAvailability*(
  self: Reservations,
  availabilityId: AvailabilityId,
  reservationId: ReservationId,
  bytes: UInt256): Future[?!void] {.async.} =

  logScope:
    reservationId
    availabilityId

  withLock(self.availabilityLock):
    without key =? key(reservationId, availabilityId), error:
      return failure(error)

    without var reservation =? (await self.get(key, Reservation)), error:
      return failure(error)

    # We are ignoring bytes that are still present in the Reservation because
    # they will be returned to Availability through `deleteReservation`.
    let bytesToBeReturned = bytes - reservation.size

    if bytesToBeReturned == 0:
      trace "No bytes are returned", requestSizeBytes = bytes, returningBytes = bytesToBeReturned
      return success()

    trace "Returning bytes", requestSizeBytes = bytes, returningBytes = bytesToBeReturned

    # First lets see if we can re-reserve the bytes, if the Repo's quota
    # is depleted then we will fail-fast as there is nothing to be done atm.
    if reserveErr =? (await self.repo.reserve(bytesToBeReturned.truncate(uint).NBytes)).errorOption:
      return failure(reserveErr.toErr(ReserveFailedError))

    without availabilityKey =? availabilityId.key, error:
      return failure(error)

    without var availability =? await self.get(availabilityKey, Availability), error:
      return failure(error)

    availability.freeSize += bytesToBeReturned

    # Update availability with returned size
    if updateErr =? (await self.updateAvailability(availability)).errorOption:

      trace "Rolling back returning bytes"
      if rollbackErr =? (await self.repo.release(bytesToBeReturned.truncate(uint).NBytes)).errorOption:
        rollbackErr.parent = updateErr
        return failure(rollbackErr)

      return failure(updateErr)

    return success()

proc release*(
  self: Reservations,
  reservationId: ReservationId,
  availabilityId: AvailabilityId,
  bytes: uint): Future[?!void] {.async.} =

  logScope:
    topics = "release"
    bytes
    reservationId
    availabilityId

  trace "releasing bytes and updating reservation"

  without key =? key(reservationId, availabilityId), error:
    return failure(error)

  without var reservation =? (await self.get(key, Reservation)), error:
    return failure(error)

  if reservation.size < bytes.u256:
    let error = newException(
      BytesOutOfBoundsError,
      "trying to release an amount of bytes that is greater than the total size of the Reservation")
    return failure(error)

  if releaseErr =? (await self.repo.release(bytes.NBytes)).errorOption:
    return failure(releaseErr.toErr(ReleaseFailedError))

  reservation.size -= bytes.u256

  # persist partially used Reservation with updated size
  if err =? (await self.update(reservation)).errorOption:

    # rollback release if an update error encountered
    trace "rolling back release"
    if rollbackErr =? (await self.repo.reserve(bytes.NBytes)).errorOption:
      rollbackErr.parent = err
      return failure(rollbackErr)
    return failure(err)

  return success()

iterator items(self: StorableIter): Future[?seq[byte]] =
  while not self.finished:
    yield self.next()

proc storables(
  self: Reservations,
  T: type SomeStorableObject,
  queryKey: Key = ReservationsKey
): Future[?!StorableIter] {.async.} =

  var iter = StorableIter()
  let query = Query.init(queryKey)
  when T is Availability:
    # should indicate key length of 4, but let the .key logic determine it
    without defaultKey =? AvailabilityId.default.key, error:
      return failure(error)
  elif T is Reservation:
    # should indicate key length of 5, but let the .key logic determine it
    without defaultKey =? key(ReservationId.default, AvailabilityId.default), error:
      return failure(error)
  else:
    raiseAssert "unknown type"

  without results =? await self.repo.metaDs.ds.query(query), error:
    return failure(error)

  # /sales/reservations
  proc next(): Future[?seq[byte]] {.async.} =
    await idleAsync()
    iter.finished = results.finished
    if not results.finished and
      res =? (await results.next()) and
      res.data.len > 0 and
      key =? res.key and
      key.namespaces.len == defaultKey.namespaces.len:

      return some res.data

    return none seq[byte]

  proc dispose(): Future[?!void] {.async.} =
    return await results.dispose()

  iter.next = next
  iter.dispose = dispose
  return success iter

proc allImpl(
  self: Reservations,
  T: type SomeStorableObject,
  queryKey: Key = ReservationsKey
): Future[?!seq[T]] {.async.} =

  var ret: seq[T] = @[]

  without storables =? (await self.storables(T, queryKey)), error:
    return failure(error)

  for storable in storables.items:
    without bytes =? (await storable):
      continue

    without obj =? T.fromJson(bytes), error:
      error "json deserialization error",
        json = string.fromBytes(bytes),
        error = error.msg
      continue

    ret.add obj

  return success(ret)

proc all*(
  self: Reservations,
  T: type SomeStorableObject
): Future[?!seq[T]] {.async.} =
  return await self.allImpl(T)

proc all*(
  self: Reservations,
  T: type SomeStorableObject,
  availabilityId: AvailabilityId
): Future[?!seq[T]] {.async.} =
  without key =? (ReservationsKey / $availabilityId):
    return failure("no key")

  return await self.allImpl(T, key)

proc findAvailability*(
  self: Reservations,
  size, duration, pricePerByte, collateralPerByte: UInt256
): Future[?Availability] {.async.} =

  without storables =? (await self.storables(Availability)), e:
    error "failed to get all storables", error = e.msg
    return none Availability

  for item in storables.items:
    if bytes =? (await item) and
      availability =? Availability.fromJson(bytes):

      if size <= availability.freeSize and
        duration <= availability.duration and
        collateralPerByte <= availability.maxCollateralPerByte and
        pricePerByte >= availability.minPricePerByte:

        trace "availability matched",
          id = availability.id,
          size, availFreeSize = availability.freeSize,
          duration, availDuration = availability.duration,
          pricePerByte, availMinPricePerByte = availability.minPricePerByte,
          collateralPerByte,
          availMaxCollateralPerByte = availability.maxCollateralPerByte

        # TODO: As soon as we're on ARC-ORC, we can use destructors
        # to automatically dispose our iterators when they fall out of scope.
        # For now:
        if err =? (await storables.dispose()).errorOption:
          error "failed to dispose storables iter", error = err.msg
          return none Availability
        return some availability

      trace "availability did not match",
        id = availability.id,
        size, availFreeSize = availability.freeSize,
        duration, availDuration = availability.duration,
        pricePerByte, availMinPricePerByte = availability.minPricePerByte,
        collateralPerByte,
        availMaxCollateralPerByte = availability.maxCollateralPerByte
