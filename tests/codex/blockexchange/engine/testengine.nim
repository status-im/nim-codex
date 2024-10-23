import std/sequtils
import std/random
import std/algorithm

import pkg/stew/byteutils
import pkg/chronos
import pkg/libp2p/errors
import pkg/libp2p/routing_record
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/rng
import pkg/codex/blockexchange
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype
import pkg/codex/utils/asyncheapqueue
import pkg/codex/manifest

import ../../../asynctest
import ../../helpers
import ../../examples

asyncchecksuite "NetworkStore engine basic":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    wallet: WalletRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    blocks: seq[Block]
    done: Future[void]

  setup:
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    chunker = RandomChunker.new(Rng.instance(), size = 1024'nb, chunkSize = 256'nb)
    wallet = WalletRef.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    done = newFuture[void]()

  test "Should send want list to new peers":
    proc sendWantList(
      id: PeerId,
      addresses: seq[BlockAddress],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.WantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe, async.} =
        check addresses.mapIt($it.cidOrTreeCid).sorted == blocks.mapIt( $it.cid ).sorted
        done.complete()

    let
      network = BlockExcNetwork(request: BlockExcRequest(
        sendWantList: sendWantList,
      ))

      localStore = CacheStore.new(blocks.mapIt( it ))
      discovery = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks)

      advertiser = Advertiser.new(
        localStore,
        blockDiscovery
      )

      engine = BlockExcEngine.new(
        localStore,
        wallet,
        network,
        discovery,
        advertiser,
        peerStore,
        pendingBlocks)

    for b in blocks:
      discard engine.pendingBlocks.getWantHandle(b.cid)
    await engine.setupPeer(peerId)

    await done.wait(100.millis)

  test "Should send account to new peers":
    let pricing = Pricing.example

    proc sendAccount(peer: PeerId, account: Account) {.gcsafe, async.} =
      check account.address == pricing.address
      done.complete()

    let
      network = BlockExcNetwork(
        request: BlockExcRequest(
          sendAccount: sendAccount
      ))

      localStore = CacheStore.new()
      discovery = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks)

      advertiser = Advertiser.new(
        localStore,
        blockDiscovery
      )

      engine = BlockExcEngine.new(
        localStore,
        wallet,
        network,
        discovery,
        advertiser,
        peerStore,
        pendingBlocks)

    engine.pricing = pricing.some
    await engine.setupPeer(peerId)

    await done.wait(100.millis)

asyncchecksuite "NetworkStore engine handlers":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    wallet: WalletRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    peerCtx: BlockExcPeerCtx
    localStore: BlockStore
    blocks: seq[Block]

  const NopSendWantCancellationsProc = proc(
    id: PeerId,
    addresses: seq[BlockAddress]
  ) {.gcsafe, async.} = discard

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024'nb, chunkSize = 256'nb)

    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    wallet = WalletRef.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork()

    discovery = DiscoveryEngine.new(
      localStore,
      peerStore,
      network,
      blockDiscovery,
      pendingBlocks)

    advertiser = Advertiser.new(
      localStore,
      blockDiscovery
    )

    engine = BlockExcEngine.new(
      localStore,
      wallet,
      network,
      discovery,
      advertiser,
      peerStore,
      pendingBlocks)

    peerCtx = BlockExcPeerCtx(
      id: peerId
    )
    engine.peers.add(peerCtx)

  test "Should schedule block requests":
    let
      wantList = makeWantList(
        blocks.mapIt( it.cid ),
        wantType = WantType.WantBlock) # only `wantBlock` are stored in `peerWants`

    proc handler() {.async.} =
      let ctx = await engine.taskQueue.pop()
      check ctx.id == peerId
      # only `wantBlock` scheduled
      check ctx.peerWants.mapIt( it.address.cidOrTreeCid ) == blocks.mapIt( it.cid )

    let done = handler()
    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list":
    let
      done = newFuture[void]()
      wantList = makeWantList(blocks.mapIt( it.cid ))

    proc sendPresence(peerId: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
      check presence.mapIt( it.address ) == wantList.entries.mapIt( it.address )
      done.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendPresence: sendPresence
    ))

    await allFuturesThrowing(
      allFinished(blocks.mapIt( localStore.putBlock(it) )))

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have`":
    let
      done = newFuture[void]()
      wantList = makeWantList(
        blocks.mapIt( it.cid ),
        sendDontHave = true)

    proc sendPresence(peerId: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
      check presence.mapIt( it.address ) == wantList.entries.mapIt( it.address )
      for p in presence:
        check:
          p.`type` == BlockPresenceType.DontHave

      done.complete()

    engine.network = BlockExcNetwork(request: BlockExcRequest(
      sendPresence: sendPresence
    ))

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have` some blocks":
    let
      done = newFuture[void]()
      wantList = makeWantList(
        blocks.mapIt( it.cid ),
        sendDontHave = true)

    proc sendPresence(peerId: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
      for p in presence:
        if p.address.cidOrTreeCid != blocks[0].cid and p.address.cidOrTreeCid != blocks[1].cid:
          check p.`type` == BlockPresenceType.DontHave
        else:
          check p.`type` == BlockPresenceType.Have

      done.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendPresence: sendPresence
    ))

    (await engine.localStore.putBlock(blocks[0])).tryGet()
    (await engine.localStore.putBlock(blocks[1])).tryGet()
    await engine.wantListHandler(peerId, wantList)

    await done

  test "Should store blocks in local store":
    let pending = blocks.mapIt(
      engine.pendingBlocks.getWantHandle( it.cid )
    )

    let blocksDelivery = blocks.mapIt(BlockDelivery(blk: it, address: it.address))

    # Install NOP for want list cancellations so they don't cause a crash
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(sendWantCancellations: NopSendWantCancellationsProc))

    await engine.blocksDeliveryHandler(peerId, blocksDelivery)
    let resolved = await allFinished(pending)
    check resolved.mapIt( it.read ) == blocks
    for b in blocks:
      let present = await engine.localStore.hasBlock(b.cid)
      check present.tryGet()

  test "Should send payments for received blocks":
    let
      done = newFuture[void]()
      account = Account(address: EthAddress.example)
      peerContext = peerStore.get(peerId)

    peerContext.account = account.some
    peerContext.blocks = blocks.mapIt(
      (it.address, Presence(address: it.address, price: rand(uint16).u256))
    ).toTable

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendPayment: proc(receiver: PeerId, payment: SignedState) {.gcsafe, async.} =
          let
            amount =
              blocks.mapIt(
                peerContext.blocks[it.address].price
              ).foldl(a + b)

            balances = !payment.state.outcome.balances(Asset)

          check receiver == peerId
          check balances[account.address.toDestination] == amount
          done.complete(),

        # Install NOP for want list cancellations so they don't cause a crash
        sendWantCancellations: NopSendWantCancellationsProc
    ))

    await engine.blocksDeliveryHandler(peerId, blocks.mapIt(
      BlockDelivery(blk: it, address: it.address)))
    await done.wait(100.millis)

  test "Should handle block presence":
    var
      handles: Table[Cid, Future[Block]]

    proc sendWantList(
      id: PeerId,
      addresses: seq[BlockAddress],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.WantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe, async.} =
        engine.pendingBlocks.resolve(blocks
        .filterIt( it.address in addresses )
        .mapIt(BlockDelivery(blk: it, address: it.address)))

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList
    ))

    # only Cids in peer want lists are requested
    handles = blocks.mapIt(
      (it.cid, engine.pendingBlocks.getWantHandle( it.cid ))).toTable

    let price = UInt256.example
    await engine.blockPresenceHandler(
      peerId,
      blocks.mapIt(
        PresenceMessage.init(
          Presence(
            address: it.address,
            have: true,
            price: price
      ))))

    for a in blocks.mapIt(it.address):
      check a in peerCtx.peerHave
      check peerCtx.blocks[a].price == price

  test "Should send cancellations for received blocks":
    let
      pending = blocks.mapIt(engine.pendingBlocks.getWantHandle(it.cid))
      blocksDelivery = blocks.mapIt(BlockDelivery(blk: it, address: it.address))
      cancellations = newTable(
        blocks.mapIt((it.address, newFuture[void]())).toSeq
      )

    proc sendWantCancellations(
      id: PeerId,
      addresses: seq[BlockAddress]
    ) {.gcsafe, async.} =
        for address in addresses:
          cancellations[address].complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantCancellations: sendWantCancellations
    ))

    await engine.blocksDeliveryHandler(peerId, blocksDelivery)
    discard await allFinished(pending)
    await allFuturesThrowing(cancellations.values().toSeq)

asyncchecksuite "Task Handler":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    wallet: WalletRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    localStore: BlockStore

    peersCtx: seq[BlockExcPeerCtx]
    peers: seq[PeerId]
    blocks: seq[Block]

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024, chunkSize = 256'nb)
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    wallet = WalletRef.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    localStore = CacheStore.new()
    network = BlockExcNetwork()

    discovery = DiscoveryEngine.new(
      localStore,
      peerStore,
      network,
      blockDiscovery,
      pendingBlocks)

    advertiser = Advertiser.new(
      localStore,
      blockDiscovery
    )

    engine = BlockExcEngine.new(
      localStore,
      wallet,
      network,
      discovery,
      advertiser,
      peerStore,
      pendingBlocks)
    peersCtx = @[]

    for i in 0..3:
      let seckey = PrivateKey.random(rng[]).tryGet()
      peers.add(PeerId.init(seckey.getPublicKey().tryGet()).tryGet())

      peersCtx.add(BlockExcPeerCtx(
        id: peers[i]
      ))
      peerStore.add(peersCtx[i])

    engine.pricing = Pricing.example.some

  test "Should send want-blocks in priority order":
    proc sendBlocksDelivery(
      id: PeerId,
      blocksDelivery: seq[BlockDelivery]) {.gcsafe, async.} =
      check blocksDelivery.len == 2
      check:
        blocksDelivery[1].address == blocks[0].address
        blocksDelivery[0].address == blocks[1].address

    for blk in blocks:
      (await engine.localStore.putBlock(blk)).tryGet()
    engine.network.request.sendBlocksDelivery = sendBlocksDelivery

    # second block to send by priority
    peersCtx[0].peerWants.add(
      WantListEntry(
        address: blocks[0].address,
        priority: 49,
        cancel: false,
        wantType: WantType.WantBlock,
        sendDontHave: false)
    )

    # first block to send by priority
    peersCtx[0].peerWants.add(
      WantListEntry(
        address: blocks[1].address,
        priority: 50,
        cancel: false,
        wantType: WantType.WantBlock,
        sendDontHave: false)
    )

    await engine.taskHandler(peersCtx[0])

  test "Should set in-flight for outgoing blocks":
    proc sendBlocksDelivery(
      id: PeerId,
      blocksDelivery: seq[BlockDelivery]) {.gcsafe, async.} =
      check peersCtx[0].peerWants[0].inFlight

    for blk in blocks:
      (await engine.localStore.putBlock(blk)).tryGet()
    engine.network.request.sendBlocksDelivery = sendBlocksDelivery

    peersCtx[0].peerWants.add(WantListEntry(
      address: blocks[0].address,
      priority: 50,
      cancel: false,
      wantType: WantType.WantBlock,
      sendDontHave: false,
      inFlight: false)
    )
    await engine.taskHandler(peersCtx[0])

  test "Should clear in-flight when local lookup fails":
    peersCtx[0].peerWants.add(WantListEntry(
      address: blocks[0].address,
      priority: 50,
      cancel: false,
      wantType: WantType.WantBlock,
      sendDontHave: false,
      inFlight: false)
    )
    await engine.taskHandler(peersCtx[0])

    check not peersCtx[0].peerWants[0].inFlight

  test "Should send presence":
    let present = blocks
    let missing = @[Block.new("missing".toBytes).tryGet()]
    let price = (!engine.pricing).price

    proc sendPresence(id: PeerId, presence: seq[BlockPresence]) {.gcsafe, async.} =
      check presence.mapIt(!Presence.init(it)) == @[
        Presence(address: present[0].address, have: true, price: price),
        Presence(address: present[1].address, have: true, price: price),
        Presence(address: missing[0].address, have: false)
      ]

    for blk in blocks:
      (await engine.localStore.putBlock(blk)).tryGet()
    engine.network.request.sendPresence = sendPresence

    # have block
    peersCtx[0].peerWants.add(
      WantListEntry(
        address: present[0].address,
        priority: 1,
        cancel: false,
        wantType: WantType.WantHave,
        sendDontHave: false)
    )

    # have block
    peersCtx[0].peerWants.add(
      WantListEntry(
        address: present[1].address,
        priority: 1,
        cancel: false,
        wantType: WantType.WantHave,
        sendDontHave: false)
    )

    # don't have block
    peersCtx[0].peerWants.add(
      WantListEntry(
        address: missing[0].address,
        priority: 1,
        cancel: false,
        wantType: WantType.WantHave,
        sendDontHave: false)
    )

    await engine.taskHandler(peersCtx[0])
