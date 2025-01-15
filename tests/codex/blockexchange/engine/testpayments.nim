import std/unittest

import pkg/codex/stores
import ../../examples
import ../../helpers

checksuite "engine payments":
  let address = EthAddress.example
  let amount = 42.u256

  var wallet: WalletRef
  var peer: BlockExcPeerCtx

  setup:
    wallet = WalletRef.example
    peer = BlockExcPeerCtx.example
    peer.account = Account(address: address).some

  test "pays for received blocks":
    let payment = !wallet.pay(peer, amount)
    let balances = payment.state.outcome.balances(Asset)
    let destination = address.toDestination
    check !balances[destination] == amount

  test "no payment when no account is set":
    peer.account = Account.none
    check wallet.pay(peer, amount).isFailure

  test "uses same channel for consecutive payments":
    let payment1, payment2 = wallet.pay(peer, amount)
    let channel1 = payment1 .? state .? channel .? getChannelId
    let channel2 = payment2 .? state .? channel .? getChannelId
    check channel1 == channel2
