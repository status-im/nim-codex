import pkg/chronos

import pkg/codex/blockexchange/protobuf/presence

import ../../../asynctest
import ../../examples
import ../../helpers

checksuite "block presence protobuf messages":
  let
    cid = Cid.example
    address = BlockAddress(leaf: false, cid: cid)
    price = UInt256.example
    presence = Presence(address: address, have: true, price: price)
    message = PresenceMessage.init(presence)

  test "encodes have/donthave":
    var presence = presence
    presence.have = true
    check PresenceMessage.init(presence).`type` == Have
    presence.have = false
    check PresenceMessage.init(presence).`type` == DontHave

  test "encodes price":
    check message.price == @(price.toBytesBE)

  test "decodes CID":
    check Presence.init(message) .? address == address.some

  test "decodes have/donthave":
    var message = message
    message.`type` = BlockPresenceType.Have
    check Presence.init(message) .? have == true.some
    message.`type` = BlockPresenceType.DontHave
    check Presence.init(message) .? have == false.some

  test "decodes price":
    check Presence.init(message) .? price == price.some

  test "fails to decode when price is invalid":
    var incorrect = message
    incorrect.price.add(0)
    check Presence.init(incorrect).isNone
