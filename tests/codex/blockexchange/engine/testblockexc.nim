import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/stew/byteutils

import pkg/codex/stores
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/discovery
import pkg/codex/blocktype as bt

import ../../../asynctest
import ../../examples
import ../../helpers

asyncchecksuite "NetworkStore engine - 2 nodes":
  var
    nodeCmps1, nodeCmps2: NodesComponents
    peerCtx1, peerCtx2: BlockExcPeerCtx
    pricing1, pricing2: Pricing
    blocks1, blocks2: seq[bt.Block]
    pendingBlocks1, pendingBlocks2: seq[Future[bt.Block]]

  setup:
    blocks1 = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
    blocks2 = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
    nodeCmps1 = generateNodes(1, blocks1)[0]
    nodeCmps2 = generateNodes(1, blocks2)[0]

    await allFuturesThrowing(
      nodeCmps1.switch.start(),
      nodeCmps1.blockDiscovery.start(),
      nodeCmps1.engine.start(),
      nodeCmps2.switch.start(),
      nodeCmps2.blockDiscovery.start(),
      nodeCmps2.engine.start(),
    )

    # initialize our want lists
    pendingBlocks1 =
      blocks2[0 .. 3].mapIt(nodeCmps1.pendingBlocks.getWantHandle(it.cid))

    pendingBlocks2 =
      blocks1[0 .. 3].mapIt(nodeCmps2.pendingBlocks.getWantHandle(it.cid))

    pricing1 = Pricing.example()
    pricing2 = Pricing.example()

    pricing1.address = nodeCmps1.wallet.address
    pricing2.address = nodeCmps2.wallet.address
    nodeCmps1.engine.pricing = pricing1.some
    nodeCmps2.engine.pricing = pricing2.some

    await nodeCmps1.switch.connect(
      nodeCmps2.switch.peerInfo.peerId, nodeCmps2.switch.peerInfo.addrs
    )

    await sleepAsync(1.seconds) # give some time to exchange lists
    peerCtx2 = nodeCmps1.peerStore.get(nodeCmps2.switch.peerInfo.peerId)
    peerCtx1 = nodeCmps2.peerStore.get(nodeCmps1.switch.peerInfo.peerId)

    check isNil(peerCtx1).not
    check isNil(peerCtx2).not

  teardown:
    await allFuturesThrowing(
      nodeCmps1.blockDiscovery.stop(),
      nodeCmps1.engine.stop(),
      nodeCmps1.switch.stop(),
      nodeCmps2.blockDiscovery.stop(),
      nodeCmps2.engine.stop(),
      nodeCmps2.switch.stop(),
    )

  test "Should exchange blocks on connect":
    await allFuturesThrowing(allFinished(pendingBlocks1)).wait(10.seconds)

    await allFuturesThrowing(allFinished(pendingBlocks2)).wait(10.seconds)

    check:
      (await allFinished(blocks1[0 .. 3].mapIt(nodeCmps2.localStore.getBlock(it.cid))))
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == blocks1[0 .. 3].mapIt($it.cid).sorted(cmp[string])

      (await allFinished(blocks2[0 .. 3].mapIt(nodeCmps1.localStore.getBlock(it.cid))))
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == blocks2[0 .. 3].mapIt($it.cid).sorted(cmp[string])

  test "Should exchanges accounts on connect":
    check peerCtx1.account .? address == pricing1.address.some
    check peerCtx2.account .? address == pricing2.address.some

  test "Should send want-have for block":
    let blk = bt.Block.new("Block 1".toBytes).tryGet()
    let blkFut = nodeCmps1.pendingBlocks.getWantHandle(blk.cid)
    (await nodeCmps2.localStore.putBlock(blk)).tryGet()

    let entry = WantListEntry(
      address: blk.address,
      priority: 1,
      cancel: false,
      wantType: WantType.WantBlock,
      sendDontHave: false,
    )

    peerCtx1.peerWants.add(entry)
    check nodeCmps2.engine.taskQueue.pushOrUpdateNoWait(peerCtx1).isOk

    check eventually (await nodeCmps1.localStore.hasBlock(blk.cid)).tryGet()
    check eventually (await blkFut) == blk

  test "Should get blocks from remote":
    let blocks =
      await allFinished(blocks2[4 .. 7].mapIt(nodeCmps1.networkStore.getBlock(it.cid)))

    check blocks.mapIt(it.read().tryGet()) == blocks2[4 .. 7]

  test "Remote should send blocks when available":
    let blk = bt.Block.new("Block 1".toBytes).tryGet()

    # should fail retrieving block from remote
    check not await blk.cid in nodeCmps1.networkStore

    # second trigger blockexc to resolve any pending requests
    # for the block
    (await nodeCmps2.networkStore.putBlock(blk)).tryGet()

    # should succeed retrieving block from remote
    check await nodeCmps1.networkStore.getBlock(blk.cid).withTimeout(100.millis)
      # should succeed

  test "Should receive payments for blocks that were sent":
    discard
      await allFinished(blocks2[4 .. 7].mapIt(nodeCmps2.networkStore.putBlock(it)))

    discard
      await allFinished(blocks2[4 .. 7].mapIt(nodeCmps1.networkStore.getBlock(it.cid)))

    let
      channel = !peerCtx1.paymentChannel
      wallet = nodeCmps2.wallet

    check eventually wallet.balance(channel, Asset) > 0

asyncchecksuite "NetworkStore - multiple nodes":
  var
    nodes: seq[NodesComponents]
    blocks: seq[bt.Block]

  setup:
    blocks = await makeRandomBlocks(datasetSize = 4096, blockSize = 256'nb)
    nodes = generateNodes(5)
    for e in nodes:
      await e.engine.start()

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

  teardown:
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

    nodes = @[]

  test "Should receive blocks for own want list":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    let
      downloadCids = blocks[0 .. 3].mapIt(it.cid) & blocks[12 .. 15].mapIt(it.cid)

      pendingBlocks = downloadCids.mapIt(engine.pendingBlocks.getWantHandle(it))

    for i in 0 .. 15:
      (await nodes[i div 4].networkStore.engine.localStore.putBlock(blocks[i])).tryGet()

    await connectNodes(nodes)
    await sleepAsync(1.seconds)

    await allFuturesThrowing(allFinished(pendingBlocks))

    check:
      (await allFinished(downloadCids.mapIt(downloader.localStore.getBlock(it))))
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == downloadCids.mapIt($it).sorted(cmp[string])

  test "Should exchange blocks with multiple nodes":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine

    # Add blocks from 1st peer to want list
    let
      pendingBlocks1 = blocks[0 .. 3].mapIt(engine.pendingBlocks.getWantHandle(it.cid))
      pendingBlocks2 =
        blocks[12 .. 15].mapIt(engine.pendingBlocks.getWantHandle(it.cid))

    for i in 0 .. 15:
      (await nodes[i div 4].networkStore.engine.localStore.putBlock(blocks[i])).tryGet()

    await connectNodes(nodes)
    await sleepAsync(1.seconds)

    await allFuturesThrowing(allFinished(pendingBlocks1), allFinished(pendingBlocks2))

    check pendingBlocks1.mapIt(it.read) == blocks[0 .. 3]
    check pendingBlocks2.mapIt(it.read) == blocks[12 .. 15]

  test "Should actively cancel want-haves if block received from elsewhere":
    let
      # Peer wanting to download blocks
      downloader = nodes[4]
      # Bystander peer - gets block request but can't satisfy them
      bystander = nodes[3]
      # Holder of actual blocks
      blockHolder = nodes[1]

    let aBlock = blocks[0]
    (await blockHolder.engine.localStore.putBlock(aBlock)).tryGet()

    await connectNodes(@[downloader, bystander])
    # Downloader asks for block...
    let blockRequest = downloader.engine.requestBlock(aBlock.cid)

    # ... and bystander learns that downloader wants it, but can't provide it.
    check eventually(
      bystander.engine.peers
      .get(downloader.switch.peerInfo.peerId).peerWants
      .filterIt(it.address == aBlock.address).len == 1
    )

    # As soon as we connect the downloader to the blockHolder, the block should
    # propagate to the downloader...
    await connectNodes(@[downloader, blockHolder])
    check (await blockRequest).tryGet().cid == aBlock.cid
    check (await downloader.engine.localStore.hasBlock(aBlock.cid)).tryGet()

    # ... and the bystander should have cancelled the want-have
    check eventually(
      bystander.engine.peers
      .get(downloader.switch.peerInfo.peerId).peerWants
      .filterIt(it.address == aBlock.address).len == 0
    )
