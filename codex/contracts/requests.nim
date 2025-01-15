import std/hashes
import std/sequtils
import std/typetraits
import pkg/contractabi
import pkg/nimcrypto
import pkg/ethers/fields
import pkg/questionable/results
import pkg/stew/byteutils
import ../logutils
import ../utils/json

export contractabi

type
  StorageRequest* = object
    client* {.serialize.}: Address
    ask* {.serialize.}: StorageAsk
    content* {.serialize.}: StorageContent
    expiry* {.serialize.}: UInt256
    nonce*: Nonce

  StorageAsk* = object
    slots* {.serialize.}: uint64
    slotSize* {.serialize.}: UInt256
    duration* {.serialize.}: UInt256
    proofProbability* {.serialize.}: UInt256
    reward* {.serialize.}: UInt256
    collateral* {.serialize.}: UInt256
    maxSlotLoss* {.serialize.}: uint64

  StorageContent* = object
    cid* {.serialize.}: string
    merkleRoot*: array[32, byte]

  Slot* = object
    request* {.serialize.}: StorageRequest
    slotIndex* {.serialize.}: UInt256

  SlotId* = distinct array[32, byte]
  RequestId* = distinct array[32, byte]
  Nonce* = distinct array[32, byte]
  RequestState* {.pure.} = enum
    New
    Started
    Cancelled
    Finished
    Failed

  SlotState* {.pure.} = enum
    Free
    Filled
    Finished
    Failed
    Paid
    Cancelled
    Repair

proc `==`*(x, y: Nonce): bool {.borrow.}
proc `==`*(x, y: RequestId): bool {.borrow.}
proc `==`*(x, y: SlotId): bool {.borrow.}
proc hash*(x: SlotId): Hash {.borrow.}
proc hash*(x: Nonce): Hash {.borrow.}
proc hash*(x: Address): Hash {.borrow.}

func toArray*(id: RequestId | SlotId | Nonce): array[32, byte] =
  array[32, byte](id)

proc `$`*(id: RequestId | SlotId | Nonce): string =
  id.toArray.toHex

proc fromHex*(T: type RequestId, hex: string): T =
  T array[32, byte].fromHex(hex)

proc fromHex*(T: type SlotId, hex: string): T =
  T array[32, byte].fromHex(hex)

proc fromHex*(T: type Nonce, hex: string): T =
  T array[32, byte].fromHex(hex)

proc fromHex*[T: distinct](_: type T, hex: string): T =
  type baseType = T.distinctBase
  T baseType.fromHex(hex)

proc toHex*[T: distinct](id: T): string =
  type baseType = T.distinctBase
  baseType(id).toHex

logutils.formatIt(LogFormat.textLines, Nonce):
  it.short0xHexLog
logutils.formatIt(LogFormat.textLines, RequestId):
  it.short0xHexLog
logutils.formatIt(LogFormat.textLines, SlotId):
  it.short0xHexLog
logutils.formatIt(LogFormat.json, Nonce):
  it.to0xHexLog
logutils.formatIt(LogFormat.json, RequestId):
  it.to0xHexLog
logutils.formatIt(LogFormat.json, SlotId):
  it.to0xHexLog

func fromTuple(_: type StorageRequest, tupl: tuple): StorageRequest =
  StorageRequest(
    client: tupl[0], ask: tupl[1], content: tupl[2], expiry: tupl[3], nonce: tupl[4]
  )

func fromTuple(_: type Slot, tupl: tuple): Slot =
  Slot(request: tupl[0], slotIndex: tupl[1])

func fromTuple(_: type StorageAsk, tupl: tuple): StorageAsk =
  StorageAsk(
    slots: tupl[0],
    slotSize: tupl[1],
    duration: tupl[2],
    proofProbability: tupl[3],
    reward: tupl[4],
    collateral: tupl[5],
    maxSlotLoss: tupl[6],
  )

func fromTuple(_: type StorageContent, tupl: tuple): StorageContent =
  StorageContent(cid: tupl[0], merkleRoot: tupl[1])

func solidityType*(_: type StorageContent): string =
  solidityType(StorageContent.fieldTypes)

func solidityType*(_: type StorageAsk): string =
  solidityType(StorageAsk.fieldTypes)

func solidityType*(_: type StorageRequest): string =
  solidityType(StorageRequest.fieldTypes)

func encode*(encoder: var AbiEncoder, content: StorageContent) =
  encoder.write(content.fieldValues)

func encode*(encoder: var AbiEncoder, ask: StorageAsk) =
  encoder.write(ask.fieldValues)

func encode*(encoder: var AbiEncoder, id: RequestId | SlotId | Nonce) =
  encoder.write(id.toArray)

func encode*(encoder: var AbiEncoder, request: StorageRequest) =
  encoder.write(request.fieldValues)

func encode*(encoder: var AbiEncoder, request: Slot) =
  encoder.write(request.fieldValues)

func decode*(decoder: var AbiDecoder, T: type StorageContent): ?!T =
  let tupl = ?decoder.read(StorageContent.fieldTypes)
  success StorageContent.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageAsk): ?!T =
  let tupl = ?decoder.read(StorageAsk.fieldTypes)
  success StorageAsk.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageRequest): ?!T =
  let tupl = ?decoder.read(StorageRequest.fieldTypes)
  success StorageRequest.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type Slot): ?!T =
  let tupl = ?decoder.read(Slot.fieldTypes)
  success Slot.fromTuple(tupl)

func id*(request: StorageRequest): RequestId =
  let encoding = AbiEncoder.encode((request,))
  RequestId(keccak256.digest(encoding).data)

func slotId*(requestId: RequestId, slotIndex: UInt256): SlotId =
  let encoding = AbiEncoder.encode((requestId, slotIndex))
  SlotId(keccak256.digest(encoding).data)

func slotId*(request: StorageRequest, slotIndex: UInt256): SlotId =
  slotId(request.id, slotIndex)

func id*(slot: Slot): SlotId =
  slotId(slot.request, slot.slotIndex)

func pricePerSlot*(ask: StorageAsk): UInt256 =
  ask.duration * ask.reward

func price*(ask: StorageAsk): UInt256 =
  ask.slots.u256 * ask.pricePerSlot

func price*(request: StorageRequest): UInt256 =
  request.ask.price

func size*(ask: StorageAsk): UInt256 =
  ask.slots.u256 * ask.slotSize
