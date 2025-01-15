import libp2p
import pkg/stint
import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ./blockexc

import ../../blocktype

export questionable
export stint
export BlockPresenceType

upraises.push:
  {.upraises: [].}

type
  PresenceMessage* = blockexc.BlockPresence
  Presence* = object
    address*: BlockAddress
    have*: bool
    price*: UInt256

func parse(_: type UInt256, bytes: seq[byte]): ?UInt256 =
  if bytes.len > 32:
    return UInt256.none
  UInt256.fromBytesBE(bytes).some

func init*(_: type Presence, message: PresenceMessage): ?Presence =
  without price =? UInt256.parse(message.price):
    return none Presence

  some Presence(
    address: message.address,
    have: message.`type` == BlockPresenceType.Have,
    price: price,
  )

func init*(_: type PresenceMessage, presence: Presence): PresenceMessage =
  PresenceMessage(
    address: presence.address,
    `type`: if presence.have: BlockPresenceType.Have else: BlockPresenceType.DontHave,
    price: @(presence.price.toBytesBE),
  )
