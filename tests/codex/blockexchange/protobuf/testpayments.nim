import pkg/chronos
import pkg/stew/byteutils
import pkg/codex/stores

import ../../../asynctest
import ../../examples
import ../../helpers

checksuite "account protobuf messages":
  let account = Account(address: EthAddress.example)
  let message = AccountMessage.init(account)

  test "encodes recipient of payments":
    check message.address == @(account.address.toArray)

  test "decodes recipient of payments":
    check Account.init(message) .? address == account.address.some

  test "fails to decode when address has incorrect number of bytes":
    var incorrect = message
    incorrect.address.del(0)
    check Account.init(incorrect).isNone

checksuite "channel update messages":
  let state = SignedState.example
  let update = StateChannelUpdate.init(state)

  test "encodes a nitro signed state":
    check update.update == state.toJson.toBytes

  test "decodes a channel update":
    check SignedState.init(update) == state.some

  test "fails to decode incorrect channel update":
    var incorrect = update
    incorrect.update.del(0)
    check SignedState.init(incorrect).isNone
