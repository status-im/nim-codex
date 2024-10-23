## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/sets
import std/options
import std/algorithm
import std/sugar

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
import pkg/metrics
import pkg/stint
import pkg/questionable

import ../../stores/blockstore
import ../../blocktype
import ../../utils
import ../../merkletree
import ../../logutils
import ../../manifest

import ../protobuf/blockexc
import ../protobuf/presence

import ../network
import ../peers

import ./payments
import ./discovery
import ./advertiser
import ./pendingblocks

export peers, pendingblocks, payments, discovery

logScope:
  topics = "codex blockexcengine"

declareCounter(codex_block_exchange_want_have_lists_sent, "codex blockexchange wantHave lists sent")
declareCounter(codex_block_exchange_want_have_lists_received, "codex blockexchange wantHave lists received")
declareCounter(codex_block_exchange_want_block_lists_sent, "codex blockexchange wantBlock lists sent")
declareCounter(codex_block_exchange_want_block_lists_received, "codex blockexchange wantBlock lists received")
declareCounter(codex_block_exchange_blocks_sent, "codex blockexchange blocks sent")
declareCounter(codex_block_exchange_blocks_received, "codex blockexchange blocks received")

const
  DefaultMaxPeersPerRequest* = 10
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  # DefaultMaxRetries = 3
  # DefaultConcurrentDiscRequests = 10
  # DefaultConcurrentAdvertRequests = 10
  # DefaultDiscoveryTimeout = 1.minutes
  # DefaultMaxQueriedBlocksCache = 1000
  # DefaultMinPeersPerBlock = 3

type
  TaskHandler* = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BlockExcPeerCtx): bool {.gcsafe.}

  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore                       # Local block store for this instance
    network*: BlockExcNetwork                     # Petwork interface
    peers*: PeerCtxStore                          # Peers we're currently actively exchanging with
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]   # Peers we're currently processing tasks for
    concurrentTasks: int                          # Number of concurrent peers we're serving at any given time
    blockexcTasks: seq[Future[void]]              # Future to control blockexc task
    blockexcRunning: bool                         # Indicates if the blockexc task is running
    pendingBlocks*: PendingBlocksManager          # Blocks we're awaiting to be resolved
    peersPerRequest: int                          # Max number of peers to request from
    wallet*: WalletRef                            # Nitro wallet for micropayments
    pricing*: ?Pricing                            # Optional bandwidth pricing
    blockFetchTimeout*: Duration                  # Timeout for fetching blocks over the network
    discovery*: DiscoveryEngine
    advertiser*: Advertiser

  Pricing* = object
    address*: EthAddress
    price*: UInt256

# attach task scheduler to engine
proc scheduleTask(b: BlockExcEngine, task: BlockExcPeerCtx): bool {.gcsafe} =
  b.taskQueue.pushOrUpdateNoWait(task).isOk()

proc blockexcTaskRunner(b: BlockExcEngine): Future[void] {.gcsafe.}

proc start*(b: BlockExcEngine) {.async.} =
  ## Start the blockexc task
  ##

  await b.discovery.start()
  await b.advertiser.start()

  trace "Blockexc starting with concurrent tasks", tasks = b.concurrentTasks
  if b.blockexcRunning:
    warn "Starting blockexc twice"
    return

  b.blockexcRunning = true
  for i in 0..<b.concurrentTasks:
    b.blockexcTasks.add(blockexcTaskRunner(b))

proc stop*(b: BlockExcEngine) {.async.} =
  ## Stop the blockexc blockexc
  ##

  await b.discovery.stop()
  await b.advertiser.stop()

  trace "NetworkStore stop"
  if not b.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  b.blockexcRunning = false
  for task in b.blockexcTasks:
    if not task.finished:
      trace "Awaiting task to stop"
      await task.cancelAndWait()
      trace "Task stopped"

  trace "NetworkStore stopped"

proc sendWantHave(
  b: BlockExcEngine,
  address: BlockAddress, # pluralize this entire call chain, please
  excluded: seq[BlockExcPeerCtx],
  peers: seq[BlockExcPeerCtx]): Future[void] {.async.} =
  trace "Sending wantHave request to peers", address
  for p in peers:
    if p notin excluded:
      if address notin p.peerHave:
        await b.network.request.sendWantList(
          p.id,
          @[address],
          wantType = WantType.WantHave) # we only want to know if the peer has the block

proc sendWantBlock(
  b: BlockExcEngine,
  address: BlockAddress, # pluralize this entire call chain, please
  blockPeer: BlockExcPeerCtx): Future[void] {.async.} =
  trace "Sending wantBlock request to", peer = blockPeer.id, address
  await b.network.request.sendWantList(
    blockPeer.id,
    @[address],
    wantType = WantType.WantBlock) # we want this remote to send us a block

proc monitorBlockHandle(
  b: BlockExcEngine,
  handle: Future[Block],
  address: BlockAddress,
  peerId: PeerId) {.async.} =

  try:
    discard await handle
  except CancelledError as exc:
    trace "Block handle cancelled", address, peerId
  except CatchableError as exc:
    warn "Error block handle, disconnecting peer", address, exc = exc.msg, peerId

    # TODO: really, this is just a quick and dirty way of
    # preventing hitting the same "bad" peer every time, however,
    # we might as well discover this on or next iteration, so
    # it doesn't mean that we're never talking to this peer again.
    # TODO: we need a lot more work around peer selection and
    # prioritization

    # drop unresponsive peer
    await b.network.switch.disconnect(peerId)
    b.discovery.queueFindBlocksReq(@[address.cidOrTreeCid])

proc requestBlock*(
  b: BlockExcEngine,
  address: BlockAddress,
): Future[?!Block] {.async.} =
  let blockFuture = b.pendingBlocks.getWantHandle(address, b.blockFetchTimeout)

  if not b.pendingBlocks.isInFlight(address):
    let peers = b.peers.selectCheapest(address)
    if peers.len == 0:
      b.discovery.queueFindBlocksReq(@[address.cidOrTreeCid])

    let maybePeer =
      if peers.len > 0:
        peers[hash(address) mod peers.len].some
      elif b.peers.len > 0:
        toSeq(b.peers)[hash(address) mod b.peers.len].some
      else:
        BlockExcPeerCtx.none

    if peer =? maybePeer:
      asyncSpawn b.monitorBlockHandle(blockFuture, address, peer.id)
      b.pendingBlocks.setInFlight(address)
      await b.sendWantBlock(address, peer)
      codex_block_exchange_want_block_lists_sent.inc()
      await b.sendWantHave(address, @[peer], toSeq(b.peers))
      codex_block_exchange_want_have_lists_sent.inc()

  # Don't let timeouts bubble up. We can't be too broad here or we break
  # cancellations.
  try:
    success await blockFuture
  except AsyncTimeoutError as err:
    failure err

proc requestBlock*(
  b: BlockExcEngine,
  cid: Cid
): Future[?!Block] =
  b.requestBlock(BlockAddress.init(cid))

proc blockPresenceHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  blocks: seq[BlockPresence]) {.async.} =
  let
    peerCtx = b.peers.get(peer)
    wantList = toSeq(b.pendingBlocks.wantList)

  if peerCtx.isNil:
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      peerCtx.setPresence(presence)

  let
    peerHave = peerCtx.peerHave
    dontWantCids = peerHave.filterIt(
      it notin wantList
    )

  if dontWantCids.len > 0:
    peerCtx.cleanPresence(dontWantCids)

  let
    wantCids = wantList.filterIt(
      it in peerHave
    )

  if wantCids.len > 0:
    trace "Peer has blocks in our wantList", peer, wantCount = wantCids.len
    discard await allFinished(
      wantCids.mapIt(b.sendWantBlock(it, peerCtx)))

  # if none of the connected peers report our wants in their have list,
  # fire up discovery
  b.discovery.queueFindBlocksReq(
    toSeq(b.pendingBlocks.wantListCids)
    .filter do(cid: Cid) -> bool:
      not b.peers.anyIt( cid in it.peerHaveCids ))

proc scheduleTasks(b: BlockExcEngine, blocksDelivery: seq[BlockDelivery]) {.async.} =
  let
    cids = blocksDelivery.mapIt( it.blk.cid )

  # schedule any new peers to provide blocks to
  for p in b.peers:
    for c in cids: # for each cid
      # schedule a peer if it wants at least one cid
      # and we have it in our local store
      if c in p.peerWantsCids:
        if await (c in b.localStore):
          if b.scheduleTask(p):
            trace "Task scheduled for peer", peer = p.id
          else:
            warn "Unable to schedule task for peer", peer = p.id

          break # do next peer

proc cancelBlocks(b: BlockExcEngine, addrs: seq[BlockAddress]) {.async.} =
  ## Tells neighboring peers that we're no longer interested in a block.
  trace "Sending block request cancellations to peers", addrs = addrs.len

  let failed = (await allFinished(
    b.peers.mapIt(
      b.network.request.sendWantCancellations(
        peer = it.id,
        addresses = addrs))))
    .filterIt(it.failed)

  if failed.len > 0:
    warn "Failed to send block request cancellations to peers", peers = failed.len

proc resolveBlocks*(b: BlockExcEngine, blocksDelivery: seq[BlockDelivery]) {.async.} =
  b.pendingBlocks.resolve(blocksDelivery)
  await b.scheduleTasks(blocksDelivery)
  await b.cancelBlocks(blocksDelivery.mapIt(it.address))

proc resolveBlocks*(b: BlockExcEngine, blocks: seq[Block]) {.async.} =
  await b.resolveBlocks(
    blocks.mapIt(
      BlockDelivery(blk: it, address: BlockAddress(leaf: false, cid: it.cid)
  )))

proc payForBlocks(engine: BlockExcEngine,
                  peer: BlockExcPeerCtx,
                  blocksDelivery: seq[BlockDelivery]) {.async.} =
  let
    sendPayment = engine.network.request.sendPayment
    price = peer.price(blocksDelivery.mapIt(it.address))

  if payment =? engine.wallet.pay(peer, price):
    trace "Sending payment for blocks", price, len = blocksDelivery.len
    await sendPayment(peer.id, payment)

proc validateBlockDelivery(
  b: BlockExcEngine,
  bd: BlockDelivery): ?!void =
  if bd.address notin b.pendingBlocks:
    return failure("Received block is not currently a pending block")

  if bd.address.leaf:
    without proof =? bd.proof:
      return failure("Missing proof")

    if proof.index != bd.address.index:
      return failure("Proof index " & $proof.index & " doesn't match leaf index " & $bd.address.index)

    without leaf =? bd.blk.cid.mhash.mapFailure, err:
      return failure("Unable to get mhash from cid for block, nested err: " & err.msg)

    without treeRoot =? bd.address.treeCid.mhash.mapFailure, err:
      return failure("Unable to get mhash from treeCid for block, nested err: " & err.msg)

    if err =? proof.verify(leaf, treeRoot).errorOption:
      return failure("Unable to verify proof for block, nested err: " & err.msg)

  else: # not leaf
    if bd.address.cid != bd.blk.cid:
      return failure("Delivery cid " & $bd.address.cid & " doesn't match block cid " & $bd.blk.cid)

  return success()

proc blocksDeliveryHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  blocksDelivery: seq[BlockDelivery]) {.async.} =
  trace "Received blocks from peer", peer, blocks = (blocksDelivery.mapIt($it.address)).join(",")

  var validatedBlocksDelivery: seq[BlockDelivery]
  for bd in blocksDelivery:
    logScope:
      peer      = peer
      address   = bd.address

    if err =? b.validateBlockDelivery(bd).errorOption:
      warn "Block validation failed", msg = err.msg
      continue

    if err =? (await b.localStore.putBlock(bd.blk)).errorOption:
      error "Unable to store block", err = err.msg
      continue

    if bd.address.leaf:
      without proof =? bd.proof:
        error "Proof expected for a leaf block delivery"
        continue
      if err =? (await b.localStore.putCidAndProof(
          bd.address.treeCid,
          bd.address.index,
          bd.blk.cid,
          proof)).errorOption:

        error "Unable to store proof and cid for a block"
        continue

    validatedBlocksDelivery.add(bd)

  await b.resolveBlocks(validatedBlocksDelivery)
  codex_block_exchange_blocks_received.inc(validatedBlocksDelivery.len.int64)

  let
    peerCtx = b.peers.get(peer)

  if peerCtx != nil:
    await b.payForBlocks(peerCtx, blocksDelivery)
    ## shouldn't we remove them from the want-list instead of this:
    peerCtx.cleanPresence(blocksDelivery.mapIt( it.address ))

proc wantListHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  wantList: WantList) {.async.} =
  let
    peerCtx = b.peers.get(peer)
  if isNil(peerCtx):
    return

  var
    presence: seq[BlockPresence]

  for e in wantList.entries:
    let
      idx = peerCtx.peerWants.findIt(it.address == e.address)

    logScope:
      peer      = peerCtx.id
      address   = e.address
      wantType  = $e.wantType

    if idx < 0: # updating entry
      let
        have = await e.address in b.localStore
        price = @(
          b.pricing.get(Pricing(price: 0.u256))
          .price.toBytesBE)

      if e.wantType == WantType.WantHave:
        codex_block_exchange_want_have_lists_received.inc()

      if not have and e.sendDontHave:
        presence.add(
          BlockPresence(
          address: e.address,
          `type`: BlockPresenceType.DontHave,
          price: price))
      elif have and e.wantType == WantType.WantHave:
        presence.add(
          BlockPresence(
          address: e.address,
          `type`: BlockPresenceType.Have,
          price: price))
      elif e.wantType == WantType.WantBlock:
        peerCtx.peerWants.add(e)
        codex_block_exchange_want_block_lists_received.inc()
    else:
      # peer doesn't want this block anymore
      if e.cancel:
        peerCtx.peerWants.del(idx)
      else:
        # peer might want to ask for the same cid with
        # different want params
        peerCtx.peerWants[idx] = e # update entry

  if presence.len > 0:
    trace "Sending presence to remote", items = presence.mapIt($it).join(",")
    await b.network.request.sendPresence(peer, presence)

  if not b.scheduleTask(peerCtx):
    warn "Unable to schedule task for peer", peer

proc accountHandler*(
  engine: BlockExcEngine,
  peer: PeerId,
  account: Account) {.async.} =
  let
    context = engine.peers.get(peer)
  if context.isNil:
    return

  context.account = account.some

proc paymentHandler*(
  engine: BlockExcEngine,
  peer: PeerId,
  payment: SignedState) {.async.} =
  trace "Handling payments", peer

  without context =? engine.peers.get(peer).option and
          account =? context.account:
    trace "No context or account for peer", peer
    return

  if channel =? context.paymentChannel:
    let
      sender = account.address
    discard engine.wallet.acceptPayment(channel, Asset, sender, payment)
  else:
    context.paymentChannel = engine.wallet.acceptChannel(payment).option

proc setupPeer*(b: BlockExcEngine, peer: PeerId) {.async.} =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up peer", peer

  if peer notin b.peers:
    trace "Setting up new peer", peer
    b.peers.add(BlockExcPeerCtx(
      id: peer
    ))
    trace "Added peer", peers = b.peers.len

  # broadcast our want list, the other peer will do the same
  if b.pendingBlocks.wantListLen > 0:
    trace "Sending our want list to a peer", peer
    let cids = toSeq(b.pendingBlocks.wantList)
    await b.network.request.sendWantList(
      peer, cids, full = true)

  if address =? b.pricing.?address:
    await b.network.request.sendAccount(peer, Account(address: address))

proc dropPeer*(b: BlockExcEngine, peer: PeerId) =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer

  # drop the peer from the peers table
  b.peers.remove(peer)

proc taskHandler*(b: BlockExcEngine, task: BlockExcPeerCtx) {.gcsafe, async.} =
  # Send to the peer blocks he wants to get,
  # if they present in our local store

  # TODO: There should be all sorts of accounting of
  # bytes sent/received here

  var
    wantsBlocks = task.peerWants.filterIt(
      it.wantType == WantType.WantBlock and not it.inFlight
    )

  proc updateInFlight(addresses: seq[BlockAddress], inFlight: bool) =
    for peerWant in task.peerWants.mitems:
      if peerWant.address in addresses:
        peerWant.inFlight = inFlight

  if wantsBlocks.len > 0:
    # Mark wants as in-flight.
    let wantAddresses = wantsBlocks.mapIt(it.address)
    updateInFlight(wantAddresses, true)
    wantsBlocks.sort(SortOrder.Descending)

    proc localLookup(e: WantListEntry): Future[?!BlockDelivery] {.async.} =
      if e.address.leaf:
        (await b.localStore.getBlockAndProof(e.address.treeCid, e.address.index)).map(
          (blkAndProof: (Block, CodexProof)) =>
            BlockDelivery(address: e.address, blk: blkAndProof[0], proof: blkAndProof[1].some)
        )
      else:
        (await b.localStore.getBlock(e.address)).map(
          (blk: Block) => BlockDelivery(address: e.address, blk: blk, proof: CodexProof.none)
        )

    let
      blocksDeliveryFut = await allFinished(wantsBlocks.map(localLookup))
      blocksDelivery = blocksDeliveryFut
        .filterIt(it.completed and it.read.isOk)
        .mapIt(it.read.get)

    # All the wants that failed local lookup must be set to not-in-flight again.
    let
      successAddresses = blocksDelivery.mapIt(it.address)
      failedAddresses = wantAddresses.filterIt(it notin successAddresses)
    updateInFlight(failedAddresses, false)

    if blocksDelivery.len > 0:
      trace "Sending blocks to peer", peer = task.id, blocks = (blocksDelivery.mapIt($it.address)).join(",")
      await b.network.request.sendBlocksDelivery(
        task.id,
        blocksDelivery
      )

      codex_block_exchange_blocks_sent.inc(blocksDelivery.len.int64)

      task.peerWants.keepItIf(it.address notin successAddresses)

proc blockexcTaskRunner(b: BlockExcEngine) {.async.} =
  ## process tasks
  ##

  trace "Starting blockexc task runner"
  while b.blockexcRunning:
    let
      peerCtx = await b.taskQueue.pop()

    await b.taskHandler(peerCtx)

  info "Exiting blockexc task runner"

proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    wallet: WalletRef,
    network: BlockExcNetwork,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    peerStore: PeerCtxStore,
    pendingBlocks: PendingBlocksManager,
    concurrentTasks = DefaultConcurrentTasks,
    peersPerRequest = DefaultMaxPeersPerRequest,
    blockFetchTimeout = DefaultBlockTimeout,
): BlockExcEngine =
  ## Create new block exchange engine instance
  ##

  let
    engine = BlockExcEngine(
      localStore: localStore,
      peers: peerStore,
      pendingBlocks: pendingBlocks,
      peersPerRequest: peersPerRequest,
      network: network,
      wallet: wallet,
      concurrentTasks: concurrentTasks,
      taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize),
      discovery: discovery,
      advertiser: advertiser,
      blockFetchTimeout: blockFetchTimeout)

  proc peerEventHandler(peerId: PeerId, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      await engine.setupPeer(peerId)
    else:
      engine.dropPeer(peerId)

  if not isNil(network.switch):
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
    peer: PeerId,
    wantList: WantList): Future[void] {.gcsafe.} =
    engine.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
    peer: PeerId,
    presence: seq[BlockPresence]): Future[void] {.gcsafe.} =
    engine.blockPresenceHandler(peer, presence)

  proc blocksDeliveryHandler(
    peer: PeerId,
    blocksDelivery: seq[BlockDelivery]): Future[void] {.gcsafe.} =
    engine.blocksDeliveryHandler(peer, blocksDelivery)

  proc accountHandler(peer: PeerId, account: Account): Future[void] {.gcsafe.} =
    engine.accountHandler(peer, account)

  proc paymentHandler(peer: PeerId, payment: SignedState): Future[void] {.gcsafe.} =
    engine.paymentHandler(peer, payment)

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocksDelivery: blocksDeliveryHandler,
    onPresence: blockPresenceHandler,
    onAccount: accountHandler,
    onPayment: paymentHandler)

  return engine
