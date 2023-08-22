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
## +--------------------------------------+              |--------------------------------------|
## |            AVAILABILITY              |              | ReservationId  | id             | PK |
## |--------------------------------------|              |--------------------------------------|
## | AvailabilityId | id            | PK  |<-||-------o<-| AvailabilityId | availabilityId | FK |
## |--------------------------------------|              |--------------------------------------|
## | UInt256        | size          |     |              | UInt256        | size           |    |
## |--------------------------------------|              |--------------------------------------|
## | UInt256        | duration      |     |              | SlotId         | slotId         |    |
## |--------------------------------------|              +--------------------------------------+
## | UInt256        | minPrice      |     |
## |--------------------------------------|
## | UInt256        | maxCollateral |     |
## +--------------------------------------+

import pkg/upraises
push: {.upraises: [].}

import std/typetraits
import pkg/chronos
import pkg/chronicles
import pkg/datastore
import pkg/nimcrypto
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/stew/byteutils
import ../stores
import ../contracts/requests
import ../utils/json

export requests

logScope:
  topics = "reservations"

type
  AvailabilityId* = distinct array[32, byte]
  ReservationId* = distinct array[32, byte]
  Availability* = object
    id* {.serialize.}: AvailabilityId
    size* {.serialize.}: UInt256
    duration* {.serialize.}: UInt256
    minPrice* {.serialize.}: UInt256
    maxCollateral* {.serialize.}: UInt256
    # used*: bool
  Reservation* = object
    id* {.serialize.}: ReservationId
    availabilityId* {.serialize.}: AvailabilityId
    size* {.serialize.}: UInt256
    slotId* {.serialize.}: SlotId
  Reservations* = ref object
    repo: RepoStore
    onAdded: ?OnAvailabilityAdded
    onMarkUnused: ?OnAvailabilityAdded
  GetNext* = proc(): Future[?Availability] {.upraises: [], gcsafe, closure.}
  OnAvailabilityAdded* = proc(availability: Availability): Future[void] {.upraises: [], gcsafe.}
  AvailabilityIter* = ref object
    finished*: bool
    next*: GetNext
  AvailabilityError* = object of CodexError
  AvailabilityAlreadyExistsError* = object of AvailabilityError
  AvailabilityReserveFailedError* = object of AvailabilityError
  AvailabilityReleaseFailedError* = object of AvailabilityError
  AvailabilityDeleteFailedError* = object of AvailabilityError
  AvailabilityGetFailedError* = object of AvailabilityError
  AvailabilityUpdateFailedError* = object of AvailabilityError

const
  SalesKey = (CodexMetaKey / "sales").tryGet # TODO: move to sales module
  ReservationsKey = (SalesKey / "reservations").tryGet

proc new*(T: type Reservations,
          repo: RepoStore): Reservations =

  T(repo: repo)

proc init*(
  _: type Availability,
  size: UInt256,
  duration: UInt256,
  minPrice: UInt256,
  maxCollateral: UInt256): Availability =

  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: AvailabilityId(id), size: size, duration: duration, minPrice: minPrice, maxCollateral: maxCollateral)

func toArray(id: AvailabilityId | ReservationId): array[32, byte] =
  array[32, byte](id)

proc `==`*(x, y: AvailabilityId): bool {.borrow.}
proc `==`*(x, y: ReservationId): bool {.borrow.}
proc `==`*(x, y: Reservation): bool =
  x.id == y.id and
  x.availabilityId == y.availabilityId and
  x.size == y.size and
  x.slotId == y.slotId
proc `==`*(x, y: Availability): bool =
  x.id == y.id and
  x.size == y.size and
  x.duration == y.duration and
  x.maxCollateral == y.maxCollateral and
  x.minPrice == y.minPrice

proc `$`*(id: AvailabilityId | ReservationId): string = id.toArray.toHex

proc toErr[E1: ref CatchableError, E2: AvailabilityError](
  e1: E1,
  _: type E2,
  msg: string = e1.msg): ref E2 =

  return newException(E2, msg, e1)

proc writeValue*(
  writer: var JsonWriter,
  value: AvailabilityId | ReservationId) {.upraises:[IOError].} =
  ## used for chronicles' logs

  mixin writeValue
  writer.writeValue %value

proc `onAdded=`*(self: Reservations,
                            onAdded: OnAvailabilityAdded) =
  self.onAdded = some onAdded

func key(id: AvailabilityId): ?!Key =
  ## sales / reservations / <availabilityId>
  (ReservationsKey / $id)

func key(reservationId: ReservationId, availabilityId: AvailabilityId): ?!Key =
  ## sales / reservations / <availabilityId> / <reservationId>
  (availabilityId.key / $reservationId)

func key*(availability: Availability | Reservation): ?!Key =
  return availability.id.key

func available*(self: Reservations): uint = self.repo.available

func hasAvailable*(self: Reservations, bytes: uint): bool =
  self.repo.available(bytes)

proc exists*(
  self: Reservations,
  id: AvailabilityId): Future[?!bool] {.async.} =

  without key =? id.key, err:
    return failure(err)

  let exists = await self.repo.metaDs.contains(key)
  return success(exists)

proc get*(
  self: Reservations,
  id: AvailabilityId): Future[?!Availability] {.async.} =

  if exists =? (await self.exists(id)) and not exists:
    let err = newException(AvailabilityGetFailedError,
      "Availability does not exist")
    return failure(err)

  without key =? id.key, err:
    return failure(err.toErr(AvailabilityGetFailedError))

  without serialized =? await self.repo.metaDs.get(key), err:
    return failure(err.toErr(AvailabilityGetFailedError))

  without availability =? Availability.fromJson(serialized), err:
    return failure(err.toErr(AvailabilityGetFailedError))

  return success availability

proc update(
  self: Reservations,
  availability: Availability): Future[?!void] {.async.} =

  trace "updating availability", id = availability.id, size = availability.size,
    used = availability.used

  without key =? availability.key, err:
    return failure(err)

  if err =? (await self.repo.metaDs.put(
    key,
    @(($ %availability).toBytes))).errorOption:
    return failure(err.toErr(AvailabilityUpdateFailedError))

  return success()

proc delete(
  self: Reservations,
  id: AvailabilityId): Future[?!void] {.async.} =

  trace "deleting availability", id

  without availability =? (await self.get(id)), err:
    return failure(err)

  without key =? availability.key, err:
    return failure(err)

  if err =? (await self.repo.metaDs.delete(key)).errorOption:
    return failure(err.toErr(AvailabilityDeleteFailedError))

  return success()

proc create*(
  self: Reservations,
  availability: Availability): Future[?!void] {.async.} =

  if exists =? (await self.exists(availability.id)) and exists:
    let err = newException(AvailabilityAlreadyExistsError,
      "Availability already exists")
    return failure(err)

  without key =? availability.key, err:
    return failure(err)

  let bytes = availability.size.truncate(uint)

  if reserveErr =? (await self.repo.reserve(bytes)).errorOption:
    return failure(reserveErr.toErr(AvailabilityReserveFailedError))

  if updateErr =? (await self.update(availability)).errorOption:

    # rollback the reserve
    trace "rolling back reserve"
    if rollbackErr =? (await self.repo.release(bytes)).errorOption:
      rollbackErr.parent = updateErr
      return failure(rollbackErr)

    return failure(updateErr)

  if onAdded =? self.onAdded:
    try:
      await onAdded(availability)
    except CatchableError as e:
      # we don't have any insight into types of errors that `onProcessSlot` can
      # throw because it is caller-defined
      warn "Unknown error during 'onAdded' callback",
        availabilityId = availability.id, error = e.msg

  return success()

proc release*(
  self: Reservations,
  id: AvailabilityId,
  bytes: uint): Future[?!void] {.async.} =

  trace "releasing bytes and updating availability", bytes, id

  without var availability =? (await self.get(id)), err:
    return failure(err)

  without key =? id.key, err:
    return failure(err)

  if releaseErr =? (await self.repo.release(bytes)).errorOption:
    return failure(releaseErr.toErr(AvailabilityReleaseFailedError))

  availability.size = (availability.size.truncate(uint) - bytes).u256

  template rollbackRelease(e: ref CatchableError) =
    trace "rolling back release"
    if rollbackErr =? (await self.repo.reserve(bytes)).errorOption:
      rollbackErr.parent = e
      return failure(rollbackErr)

  # remove completely used availabilities
  if availability.size == 0.u256:
    if err =? (await self.delete(availability.id)).errorOption:
      rollbackRelease(err)
      return failure(err)

    return success()

  # persist partially used availability with updated size
  if err =? (await self.update(availability)).errorOption:
    rollbackRelease(err)
    return failure(err)

  return success()

iterator items*(self: AvailabilityIter): Future[?Availability] =
  while not self.finished:
    yield self.next()

proc availabilities*(
  self: Reservations): Future[?!AvailabilityIter] {.async.} =

  var iter = AvailabilityIter()
  let query = Query.init(ReservationsKey)

  without results =? await self.repo.metaDs.query(query), err:
    return failure(err)

  proc next(): Future[?Availability] {.async.} =
    await idleAsync()
    iter.finished = results.finished
    if not results.finished and
      r =? (await results.next()) and
      serialized =? r.data and
      serialized.len > 0:

      return Availability.fromJson(serialized).option

    return none Availability

  iter.next = next
  return success iter

proc unused*(r: Reservations): Future[?!seq[Availability]] {.async.} =
  var ret: seq[Availability] = @[]

  without availabilities =? (await r.availabilities), err:
    return failure(err)

  for a in availabilities:
    if availability =? (await a) and not availability.used:
      ret.add availability

  return success(ret)

proc find*(
  self: Reservations,
  size, duration, minPrice, collateral: UInt256,
  used: bool): Future[?Availability] {.async.} =


  without availabilities =? (await self.availabilities), err:
    error "failed to get all availabilities", error = err.msg
    return none Availability

  for a in availabilities:
    if availability =? (await a):

      if used == availability.used and
        size <= availability.size and
        duration <= availability.duration and
        collateral <= availability.maxCollateral and
        minPrice >= availability.minPrice:

        trace "availability matched",
          used, availUsed = availability.used,
          size, availsize = availability.size,
          duration, availDuration = availability.duration,
          minPrice, availMinPrice = availability.minPrice,
          collateral, availMaxCollateral = availability.maxCollateral

        return some availability

      trace "availiability did not match",
        used, availUsed = availability.used,
        size, availsize = availability.size,
        duration, availDuration = availability.duration,
        minPrice, availMinPrice = availability.minPrice,
        collateral, availMaxCollateral = availability.maxCollateral
