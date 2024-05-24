## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##
##                                                       +--------------------------------------+
##                                                       |            RESERVATION               |
## +----------------------------------------+              |--------------------------------------|
## |            AVAILABILITY                |              | ReservationId  | id             | PK |
## |----------------------------------------|              |--------------------------------------|
## | AvailabilityId   | id            | PK  |<-||-------o<-| AvailabilityId | availabilityId | FK |
## |----------------------------------------|              |--------------------------------------|
## | UInt256          | totalSize     |     |              | UInt256        | size           |    |
## |----------------------------------------|              |--------------------------------------|
## | UInt256          | freeSize      |     |              | SlotId         | slotId         |    |
## |----------------------------------------|              +--------------------------------------+
## | UInt256          | duration      |     |
## |----------------------------------------|
## | UInt256          | minPrice      |     |
## |----------------------------------------|
## | UInt256          | maxCollateral |     |
## +----------------------------------------+

import pkg/upraises
push: {.upraises: [].}

import std/typetraits
import std/sequtils
import pkg/chronos
import pkg/datastore
import pkg/nimcrypto
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/stew/byteutils
import ../logutils
import ../clock
import ../stores
import ../market
import ../contracts/requests
import ../utils/json

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
    minPrice* {.serialize.}: UInt256
    maxCollateral* {.serialize.}: UInt256
    # 0 means non-restricted, otherwise contains timestamp until the Availability will be renewed
    until* {.serialize.}: SecondsSince1970
    # false means that the availability won't be immidiatelly considered for sale
    enabled* {.serialize.}: bool

  Reservation* = ref object
    id* {.serialize.}: ReservationId
    availabilityId* {.serialize.}: AvailabilityId
    reservedSize* {.serialize.}: UInt256
    totalSize* {.serialize.}: UInt256
    requestId* {.serialize.}: RequestId
    slotIndex* {.serialize.}: UInt256

  Reservations* = ref object
    repo: RepoStore
    clock: Clock
    onAvailabilityAdded: ?OnAvailabilityAdded

  GetNext* = proc(): Future[?seq[byte]] {.upraises: [], gcsafe, closure.}
  OnAvailabilityAdded* = proc(availability: Availability): Future[void] {.upraises: [], gcsafe.}
  StorableIter* = ref object
    finished*: bool
    next*: GetNext
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

proc new*(T: type Reservations,
          repo: RepoStore,
          clock: Clock): Reservations =

  T(repo: repo, clock: clock)

proc init*(
  _: type Availability,
  totalSize: UInt256,
  freeSize: UInt256,
  duration: UInt256,
  minPrice: UInt256,
  maxCollateral: UInt256): Availability =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: AvailabilityId(id), totalSize:totalSize, freeSize: freeSize, duration: duration, minPrice: minPrice, maxCollateral: maxCollateral)

proc init*(
  _: type Reservation,
  availabilityId: AvailabilityId,
  totalSize: UInt256,
  reservedSize: UInt256,
  requestId: RequestId,
  slotIndex: UInt256
): Reservation =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Reservation(id: ReservationId(id), availabilityId: availabilityId, totalSize: totalSize, reservedSize: reservedSize, requestId: requestId, slotIndex: slotIndex)

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

func key*(reservation: Reservation): ?!Key =
  return key(reservation.id, reservation.availabilityId)

func available*(self: Reservations): uint = self.repo.available

func hasAvailable*(self: Reservations, bytes: uint): bool =
  self.repo.available(bytes)

proc exists*(
  self: Reservations,
  key: Key): Future[bool] {.async.} =

  return await self.repo.metaDs.contains(key)

proc getImpl(
  self: Reservations,
  key: Key): Future[?!seq[byte]] {.async.} =

  if not await self.exists(key):
    let err = newException(NotExistsError, "object with key " & $key & " does not exist")
    return failure(err)

  without serialized =? await self.repo.metaDs.get(key), error:
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

  if err =? (await self.repo.metaDs.put(
    key,
    @(obj.toJson.toBytes)
  )).errorOption:
    return failure(err.toErr(UpdateFailedError))

  return success()

proc update*(
  self: Reservations,
  obj: Reservation): Future[?!void] {.async.} =
  return await self.updateImpl(obj)

proc update*(
  self: Reservations,
  obj: Availability): Future[?!void] {.async.} =

  without key =? obj.key, error:
    return failure(error)

  let getResult = await self.get(key, Availability)

  if getResult.isOk:
    let oldAvailability = !getResult

    # Sizing of the availability changed, we need to adjust the repo reservation accordingly
    if oldAvailability.totalSize != obj.totalSize:
      if oldAvailability.totalSize < obj.totalSize: # storage added
        if reserveErr =? (await self.repo.reserve((obj.totalSize - oldAvailability.totalSize).truncate(uint))).errorOption:
          return failure(reserveErr.toErr(ReserveFailedError))

      elif oldAvailability.totalSize > obj.totalSize: # storage removed
        if reserveErr =? (await self.repo.release((oldAvailability.totalSize - obj.totalSize).truncate(uint))).errorOption:
          return failure(reserveErr.toErr(ReleaseFailedError))
  else:
    let err = getResult.error()
    if not (err of NotExistsError):
      return failure(err)

  return await self.updateImpl(obj)

proc delete(
  self: Reservations,
  key: Key): Future[?!void] {.async.} =

  trace "deleting object", key

  if not await self.exists(key):
    return success()

  if err =? (await self.repo.metaDs.delete(key)).errorOption:
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

  without reservation =? (await self.get(key, Reservation)), error:
    if error of NotExistsError:
      return success()
    else:
      return failure(error)

  without availabilityKey =? availabilityId.key, error:
    return failure(error)

  without var availability =? await self.get(availabilityKey, Availability), error:
    return failure(error)

  if reservation.reservedSize > 0.u256:
    trace "returning remaining reservation bytes to availability",
      size = reservation.reservedSize

    availability.freeSize += reservation.reservedSize

    if updateErr =? (await self.update(availability)).errorOption:
      return failure(updateErr)

  if err =? (await self.repo.metaDs.delete(key)).errorOption:
    return failure(err.toErr(DeleteFailedError))

  return success()

proc createAvailability*(
  self: Reservations,
  size: UInt256,
  duration: UInt256,
  minPrice: UInt256,
  maxCollateral: UInt256,
  until: SecondsSince1970 = 0,
  enabled = true): Future[?!Availability] {.async.} =

  trace "creating availability", size, duration, minPrice, maxCollateral

  let availability = Availability.init(
    size, size, duration, minPrice, maxCollateral, until, enabled
  )
  let bytes = availability.freeSize.truncate(uint)

  if reserveErr =? (await self.repo.reserve(bytes)).errorOption:
    return failure(reserveErr.toErr(ReserveFailedError))

  if updateErr =? (await self.update(availability)).errorOption:

    # rollback the reserve
    trace "rolling back reserve"
    if rollbackErr =? (await self.repo.release(bytes)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  # we won't trigger the callback if the availability is not enabled
  if enabled and onAvailabilityAdded =? self.onAvailabilityAdded:
    try:
      await onAvailabilityAdded(availability)
    except CancelledError as error:
      raise error
    except CatchableError as e:
      # we don't have any insight into types of errors that `onProcessSlot` can
      # throw because it is caller-defined
      warn "Unknown error during 'onAvailabilityAdded' callback",
        availabilityId = availability.id, error = e.msg

  return success(availability)

proc createReservation*(
  self: Reservations,
  availabilityId: AvailabilityId,
  slotSize: UInt256,
  requestId: RequestId,
  slotIndex: UInt256
): Future[?!Reservation] {.async.} =

  trace "creating reservation", availabilityId, slotSize, requestId, slotIndex

  let reservation = Reservation.init(availabilityId, slotSize, slotSize, requestId, slotIndex)

  without availabilityKey =? availabilityId.key, error:
    return failure(error)

  without var availability =? await self.get(availabilityKey, Availability), error:
    return failure(error)

  if availability.freeSize < slotSize:
    let error = newException(
      BytesOutOfBoundsError,
      "trying to reserve an amount of bytes that is greater than the total size of the Availability")
    return failure(error)

  if createResErr =? (await self.update(reservation)).errorOption:
    return failure(createResErr)

  # reduce availability freeSize by the slot size, which is now accounted for in
  # the newly created Reservation
  availability.freeSize -= slotSize

  # update availability with reduced size
  if updateErr =? (await self.update(availability)).errorOption:

    trace "rolling back reservation creation"

    without key =? reservation.key, keyError:
      keyError.parent = updateErr
      return failure(keyError)

    # rollback the reservation creation
    if rollbackErr =? (await self.delete(key)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  return success(reservation)

proc returnBytesToAvailability*(
  self: Reservations,
  availabilityId: AvailabilityId,
  reservationId: ReservationId,
  bytes: UInt256): Future[?!void] {.async.} =

  logScope:
    reservationId
    availabilityId

  without key =? key(reservationId, availabilityId), error:
    return failure(error)

  without var reservation =? (await self.get(key, Reservation)), error:
    return failure(error)

  # We are ignoring bytes that are still present in the Reservation because
  # they will be returned to Availability through `deleteReservation`.
  let bytesToBeReturned = bytes - reservation.reservedSize

  if bytesToBeReturned == 0:
    trace "No bytes are returned", requestSizeBytes = bytes, returningBytes = bytesToBeReturned
    return success()

  trace "Returning bytes", requestSizeBytes = bytes, returningBytes = bytesToBeReturned

  # First lets see if we can re-reserve the bytes, if the Repo's quota
  # is depleted then we will fail-fast as there is nothing to be done atm.
  if reserveErr =? (await self.repo.reserve(bytesToBeReturned.truncate(uint))).errorOption:
    return failure(reserveErr.toErr(ReserveFailedError))

  without availabilityKey =? availabilityId.key, error:
    return failure(error)

  without var availability =? await self.get(availabilityKey, Availability), error:
    return failure(error)

  availability.freeSize += bytesToBeReturned

  # Update availability with returned size
  if updateErr =? (await self.update(availability)).errorOption:

    trace "Rolling back returning bytes"
    if rollbackErr =? (await self.repo.release(bytesToBeReturned.truncate(uint))).errorOption:
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

  if reservation.reservedSize < bytes.u256:
    let error = newException(
      BytesOutOfBoundsError,
      "trying to release an amount of bytes that is greater than the total size of the Reservation")
    return failure(error)

  if releaseErr =? (await self.repo.release(bytes)).errorOption:
    return failure(releaseErr.toErr(ReleaseFailedError))

  reservation.reservedSize -= bytes.u256

  # persist partially used Reservation with updated size
  if err =? (await self.update(reservation)).errorOption:

    # rollback release if an update error encountered
    trace "rolling back release"
    if rollbackErr =? (await self.repo.reserve(bytes)).errorOption:
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

  without results =? await self.repo.metaDs.query(query), error:
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

  iter.next = next
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
  size, duration, minPrice, collateral: UInt256
): Future[?Availability] {.async.} =

  without storables =? (await self.storables(Availability)), e:
    error "failed to get all storables", error = e.msg
    return none Availability

  for item in storables.items:
    if bytes =? (await item) and
      availability =? Availability.fromJson(bytes):

      if size <= availability.freeSize and
        duration <= availability.duration and
        collateral <= availability.maxCollateral and
        minPrice >= availability.minPrice:

        trace "availability matched",
          size, availFreeSize = availability.freeSize,
          duration, availDuration = availability.duration,
          minPrice, availMinPrice = availability.minPrice,
          collateral, availMaxCollateral = availability.maxCollateral

        return some availability

      trace "availability did not match",
        size, availFreeSize = availability.freeSize,
        duration, availDuration = availability.duration,
        minPrice, availMinPrice = availability.minPrice,
        collateral, availMaxCollateral = availability.maxCollateral
