# Protocol of data exchange between Codex nodes
# and Protobuf encoder/decoder for these messages.
#
# Eventually all this code should be auto-generated from message.proto.
import std/sugar

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p/cid

import pkg/questionable

import ../../units

import ../../merkletree
import ../../blocktype

const
  MaxBlockSize* = 100.MiBs.uint
  MaxMessageSize* = 100.MiBs.uint

type
  WantType* = enum
    WantBlock = 0
    WantHave = 1

  WantListEntry* = object
    address*: BlockAddress
    priority*: int32 # The priority (normalized). default to 1
    cancel*: bool # Whether this revokes an entry
    wantType*: WantType # Note: defaults to enum 0, ie Block
    sendDontHave*: bool # Note: defaults to false
    inFlight*: bool # Whether block sending is in progress. Not serialized.

  WantList* = object
    entries*: seq[WantListEntry] # A list of wantList entries
    full*: bool # Whether this is the full wantList. default to false

  BlockDelivery* = object
    blk*: Block
    address*: BlockAddress
    proof*: ?CodexProof # Present only if `address.leaf` is true

  BlockPresenceType* = enum
    Have = 0
    DontHave = 1

  BlockPresence* = object
    address*: BlockAddress
    `type`*: BlockPresenceType
    price*: seq[byte] # Amount of assets to pay for the block (UInt256)

  AccountMessage* = object
    address*: seq[byte] # Ethereum address to which payments should be made

  StateChannelUpdate* = object
    update*: seq[byte] # Signed Nitro state, serialized as JSON

  Message* = object
    wantList*: WantList
    payload*: seq[BlockDelivery]
    blockPresences*: seq[BlockPresence]
    pendingBytes*: uint
    account*: AccountMessage
    payment*: StateChannelUpdate

#
# Encoding Message into seq[byte] in Protobuf format
#

proc write*(pb: var ProtoBuffer, field: int, value: BlockAddress) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.leaf.uint)
  if value.leaf:
    ipb.write(2, value.treeCid.data.buffer)
    ipb.write(3, value.index.uint64)
  else:
    ipb.write(4, value.cid.data.buffer)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: WantListEntry) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.write(2, value.priority.uint64)
  ipb.write(3, value.cancel.uint)
  ipb.write(4, value.wantType.uint)
  ipb.write(5, value.sendDontHave.uint)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: WantList) =
  var ipb = initProtoBuffer()
  for v in value.entries:
    ipb.write(1, v)
  ipb.write(2, value.full.uint)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: BlockDelivery) =
  var ipb = initProtoBuffer(maxSize = MaxBlockSize)
  ipb.write(1, value.blk.cid.data.buffer)
  ipb.write(2, value.blk.data)
  ipb.write(3, value.address)
  if value.address.leaf:
    if proof =? value.proof:
      ipb.write(4, proof.encode())
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: BlockPresence) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.write(2, value.`type`.uint)
  ipb.write(3, value.price)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: AccountMessage) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, value: StateChannelUpdate) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.update)
  ipb.finish()
  pb.write(field, ipb)

proc protobufEncode*(value: Message): seq[byte] =
  var ipb = initProtoBuffer(maxSize = MaxMessageSize)
  ipb.write(1, value.wantList)
  for v in value.payload:
    ipb.write(3, v)
  for v in value.blockPresences:
    ipb.write(4, v)
  ipb.write(5, value.pendingBytes)
  ipb.write(6, value.account)
  ipb.write(7, value.payment)
  ipb.finish()
  ipb.buffer

#
# Decoding Message from seq[byte] in Protobuf format
#
proc decode*(_: type BlockAddress, pb: ProtoBuffer): ProtoResult[BlockAddress] =
  var
    value: BlockAddress
    leaf: bool
    field: uint64
    cidBuf = newSeq[byte]()

  if ?pb.getField(1, field):
    leaf = bool(field)

  if leaf:
    var
      treeCid: Cid
      index: Natural
    if ?pb.getField(2, cidBuf):
      treeCid = ?Cid.init(cidBuf).mapErr(x => ProtoError.IncorrectBlob)
    if ?pb.getField(3, field):
      index = field
    value = BlockAddress(leaf: true, treeCid: treeCid, index: index)
  else:
    var cid: Cid
    if ?pb.getField(4, cidBuf):
      cid = ?Cid.init(cidBuf).mapErr(x => ProtoError.IncorrectBlob)
    value = BlockAddress(leaf: false, cid: cid)

  ok(value)

proc decode*(_: type WantListEntry, pb: ProtoBuffer): ProtoResult[WantListEntry] =
  var
    value = WantListEntry()
    field: uint64
    ipb: ProtoBuffer
  if ?pb.getField(1, ipb):
    value.address = ?BlockAddress.decode(ipb)
  if ?pb.getField(2, field):
    value.priority = int32(field)
  if ?pb.getField(3, field):
    value.cancel = bool(field)
  if ?pb.getField(4, field):
    value.wantType = WantType(field)
  if ?pb.getField(5, field):
    value.sendDontHave = bool(field)
  ok(value)

proc decode*(_: type WantList, pb: ProtoBuffer): ProtoResult[WantList] =
  var
    value = WantList()
    field: uint64
    sublist: seq[seq[byte]]
  if ?pb.getRepeatedField(1, sublist):
    for item in sublist:
      value.entries.add(?WantListEntry.decode(initProtoBuffer(item)))
  if ?pb.getField(2, field):
    value.full = bool(field)
  ok(value)

proc decode*(_: type BlockDelivery, pb: ProtoBuffer): ProtoResult[BlockDelivery] =
  var
    value = BlockDelivery()
    dataBuf = newSeq[byte]()
    cidBuf = newSeq[byte]()
    cid: Cid
    ipb: ProtoBuffer

  if ?pb.getField(1, cidBuf):
    cid = ?Cid.init(cidBuf).mapErr(x => ProtoError.IncorrectBlob)
  if ?pb.getField(2, dataBuf):
    value.blk =
      ?Block.new(cid, dataBuf, verify = true).mapErr(x => ProtoError.IncorrectBlob)
  if ?pb.getField(3, ipb):
    value.address = ?BlockAddress.decode(ipb)

  if value.address.leaf:
    var proofBuf = newSeq[byte]()
    if ?pb.getField(4, proofBuf):
      let proof = ?CodexProof.decode(proofBuf).mapErr(x => ProtoError.IncorrectBlob)
      value.proof = proof.some
    else:
      value.proof = CodexProof.none
  else:
    value.proof = CodexProof.none

  ok(value)

proc decode*(_: type BlockPresence, pb: ProtoBuffer): ProtoResult[BlockPresence] =
  var
    value = BlockPresence()
    field: uint64
    ipb: ProtoBuffer
  if ?pb.getField(1, ipb):
    value.address = ?BlockAddress.decode(ipb)
  if ?pb.getField(2, field):
    value.`type` = BlockPresenceType(field)
  discard ?pb.getField(3, value.price)
  ok(value)

proc decode*(_: type AccountMessage, pb: ProtoBuffer): ProtoResult[AccountMessage] =
  var value = AccountMessage()
  discard ?pb.getField(1, value.address)
  ok(value)

proc decode*(
    _: type StateChannelUpdate, pb: ProtoBuffer
): ProtoResult[StateChannelUpdate] =
  var value = StateChannelUpdate()
  discard ?pb.getField(1, value.update)
  ok(value)

proc protobufDecode*(_: type Message, msg: seq[byte]): ProtoResult[Message] =
  var
    value = Message()
    pb = initProtoBuffer(msg, maxSize = MaxMessageSize)
    ipb: ProtoBuffer
    sublist: seq[seq[byte]]
  if ?pb.getField(1, ipb):
    value.wantList = ?WantList.decode(ipb)
  if ?pb.getRepeatedField(3, sublist):
    for item in sublist:
      value.payload.add(
        ?BlockDelivery.decode(initProtoBuffer(item, maxSize = MaxBlockSize))
      )
  if ?pb.getRepeatedField(4, sublist):
    for item in sublist:
      value.blockPresences.add(?BlockPresence.decode(initProtoBuffer(item)))
  discard ?pb.getField(5, value.pendingBytes)
  if ?pb.getField(6, ipb):
    value.account = ?AccountMessage.decode(ipb)
  if ?pb.getField(7, ipb):
    value.payment = ?StateChannelUpdate.decode(ipb)
  ok(value)
