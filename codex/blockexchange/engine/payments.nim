## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/math
import pkg/nitro
import pkg/questionable/results
import ../peers

export nitro
export results

push:
  {.upraises: [].}

const ChainId* = 0.u256 # invalid chain id for now
const Asset* = EthAddress.zero # invalid ERC20 asset address for now
const AmountPerChannel = (10'u64 ^ 18).u256 # 1 asset, ERC20 default is 18 decimals

func openLedgerChannel*(
    wallet: WalletRef, hub: EthAddress, asset: EthAddress
): ?!ChannelId =
  wallet.openLedgerChannel(hub, ChainId, asset, AmountPerChannel)

func getOrOpenChannel(wallet: WalletRef, peer: BlockExcPeerCtx): ?!ChannelId =
  if channel =? peer.paymentChannel:
    success channel
  elif account =? peer.account:
    let channel = ?wallet.openLedgerChannel(account.address, Asset)
    peer.paymentChannel = channel.some
    success channel
  else:
    failure "no account set for peer"

func pay*(wallet: WalletRef, peer: BlockExcPeerCtx, amount: UInt256): ?!SignedState =
  if account =? peer.account:
    let asset = Asset
    let receiver = account.address
    let channel = ?wallet.getOrOpenChannel(peer)
    wallet.pay(channel, asset, receiver, amount)
  else:
    failure "no account set for peer"
