import pkg/stew/byteutils
import pkg/stint
import pkg/nitro
import pkg/questionable
import pkg/upraises
import ./blockexc

export AccountMessage
export StateChannelUpdate

export stint
export nitro

push:
  {.upraises: [].}

type Account* = object
  address*: EthAddress

func init*(_: type AccountMessage, account: Account): AccountMessage =
  AccountMessage(address: @(account.address.toArray))

func parse(_: type EthAddress, bytes: seq[byte]): ?EthAddress =
  var address: array[20, byte]
  if bytes.len != address.len:
    return EthAddress.none
  for i in 0 ..< address.len:
    address[i] = bytes[i]
  EthAddress(address).some

func init*(_: type Account, message: AccountMessage): ?Account =
  without address =? EthAddress.parse(message.address):
    return none Account
  some Account(address: address)

func init*(_: type StateChannelUpdate, state: SignedState): StateChannelUpdate =
  StateChannelUpdate(update: state.toJson.toBytes)

proc init*(_: type SignedState, update: StateChannelUpdate): ?SignedState =
  SignedState.fromJson(string.fromBytes(update.update))
