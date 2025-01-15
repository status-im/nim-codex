import std/sequtils
import std/tables

import pkg/chronos

import pkg/codex/rng
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/blockexchange

import ../../asynctest
import ../examples
import ../helpers

asyncchecksuite "Network - Handlers":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    network: BlockExcNetwork
    networkPeer: NetworkPeer
    buffer: BufferStream
    blocks: seq[bt.Block]
    done: Future[void]

  proc getConn(): Future[Connection] {.async.} =
    return Connection(buffer)

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    done = newFuture[void]()
    buffer = BufferStream.new()
    network = BlockExcNetwork.new(switch = newStandardSwitch(), connProvider = getConn)
    network.setupPeer(peerId)
    networkPeer = network.peers[peerId]
    discard await networkPeer.connect()

  test "Want List handler":
    proc wantListHandler(peer: PeerId, wantList: WantList) {.gcsafe, async.} =
      # check that we got the correct amount of entries
      check wantList.entries.len == 4

      for b in blocks:
        check b.address in wantList.entries
        let entry = wantList.entries[wantList.entries.find(b.address)]
        check entry.wantType == WantType.WantHave
        check entry.priority == 1
        check entry.cancel == true
        check entry.sendDontHave == true

      done.complete()

    network.handlers.onWantList = wantListHandler

    let wantList =
      makeWantList(blocks.mapIt(it.cid), 1, true, WantType.WantHave, true, true)

    let msg = Message(wantlist: wantList)
    await buffer.pushData(lenPrefix(protobufEncode(msg)))

    await done.wait(500.millis)

  test "Blocks Handler":
    proc blocksDeliveryHandler(
        peer: PeerId, blocksDelivery: seq[BlockDelivery]
    ) {.gcsafe, async.} =
      check blocks == blocksDelivery.mapIt(it.blk)
      done.complete()

    network.handlers.onBlocksDelivery = blocksDeliveryHandler

    let msg =
      Message(payload: blocks.mapIt(BlockDelivery(blk: it, address: it.address)))
    await buffer.pushData(lenPrefix(protobufEncode(msg)))

    await done.wait(500.millis)

  test "Presence Handler":
    proc presenceHandler(peer: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
      for b in blocks:
        check:
          b.address in presence

      done.complete()

    network.handlers.onPresence = presenceHandler

    let msg = Message(
      blockPresences:
        blocks.mapIt(BlockPresence(address: it.address, type: BlockPresenceType.Have))
    )
    await buffer.pushData(lenPrefix(protobufEncode(msg)))

    await done.wait(500.millis)

  test "Handles account messages":
    let account = Account(address: EthAddress.example)

    proc handleAccount(peer: PeerId, received: Account) {.gcsafe, async.} =
      check received == account
      done.complete()

    network.handlers.onAccount = handleAccount

    let message = Message(account: AccountMessage.init(account))
    await buffer.pushData(lenPrefix(protobufEncode(message)))

    await done.wait(100.millis)

  test "Handles payment messages":
    let payment = SignedState.example

    proc handlePayment(peer: PeerId, received: SignedState) {.gcsafe, async.} =
      check received == payment
      done.complete()

    network.handlers.onPayment = handlePayment

    let message = Message(payment: StateChannelUpdate.init(payment))
    await buffer.pushData(lenPrefix(protobufEncode(message)))

    await done.wait(100.millis)

asyncchecksuite "Network - Senders":
  let chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    switch1, switch2: Switch
    network1, network2: BlockExcNetwork
    blocks: seq[bt.Block]
    done: Future[void]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    done = newFuture[void]()
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()
    network1 = BlockExcNetwork.new(switch = switch1)
    switch1.mount(network1)

    network2 = BlockExcNetwork.new(switch = switch2)
    switch2.mount(network2)

    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)

  teardown:
    await allFuturesThrowing(switch1.stop(), switch2.stop())

  test "Send want list":
    proc wantListHandler(peer: PeerId, wantList: WantList) {.gcsafe, async.} =
      # check that we got the correct amount of entries
      check wantList.entries.len == 4

      for b in blocks:
        check b.address in wantList.entries
        let entry = wantList.entries[wantList.entries.find(b.address)]
        check entry.wantType == WantType.WantHave
        check entry.priority == 1
        check entry.cancel == true
        check entry.sendDontHave == true

      done.complete()

    network2.handlers.onWantList = wantListHandler
    await network1.sendWantList(
      switch2.peerInfo.peerId,
      blocks.mapIt(it.address),
      1,
      true,
      WantType.WantHave,
      true,
      true,
    )

    await done.wait(500.millis)

  test "send blocks":
    proc blocksDeliveryHandler(
        peer: PeerId, blocksDelivery: seq[BlockDelivery]
    ) {.gcsafe, async.} =
      check blocks == blocksDelivery.mapIt(it.blk)
      done.complete()

    network2.handlers.onBlocksDelivery = blocksDeliveryHandler
    await network1.sendBlocksDelivery(
      switch2.peerInfo.peerId, blocks.mapIt(BlockDelivery(blk: it, address: it.address))
    )

    await done.wait(500.millis)

  test "send presence":
    proc presenceHandler(peer: PeerId, precense: seq[BlockPresence]) {.gcsafe, async.} =
      for b in blocks:
        check:
          b.address in precense

      done.complete()

    network2.handlers.onPresence = presenceHandler

    await network1.sendBlockPresence(
      switch2.peerInfo.peerId,
      blocks.mapIt(BlockPresence(address: it.address, type: BlockPresenceType.Have)),
    )

    await done.wait(500.millis)

  test "send account":
    let account = Account(address: EthAddress.example)

    proc handleAccount(peer: PeerId, received: Account) {.gcsafe, async.} =
      check received == account
      done.complete()

    network2.handlers.onAccount = handleAccount

    await network1.sendAccount(switch2.peerInfo.peerId, account)
    await done.wait(500.millis)

  test "send payment":
    let payment = SignedState.example

    proc handlePayment(peer: PeerId, received: SignedState) {.gcsafe, async.} =
      check received == payment
      done.complete()

    network2.handlers.onPayment = handlePayment

    await network1.sendPayment(switch2.peerInfo.peerId, payment)
    await done.wait(500.millis)

asyncchecksuite "Network - Test Limits":
  var
    switch1, switch2: Switch
    network1, network2: BlockExcNetwork
    done: Future[void]

  setup:
    done = newFuture[void]()
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()

    network1 = BlockExcNetwork.new(switch = switch1, maxInflight = 0)
    switch1.mount(network1)

    network2 = BlockExcNetwork.new(switch = switch2)
    switch2.mount(network2)

    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)

  teardown:
    await allFuturesThrowing(switch1.stop(), switch2.stop())

  test "Concurrent Sends":
    let account = Account(address: EthAddress.example)
    network2.handlers.onAccount = proc(
        peer: PeerId, received: Account
    ) {.gcsafe, async.} =
      check false

    let fut = network1.send(
      switch2.peerInfo.peerId, Message(account: AccountMessage.init(account))
    )

    await sleepAsync(100.millis)
    check not fut.finished
