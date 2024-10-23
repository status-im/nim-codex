import std/tables
import std/times
import std/cpuinfo

import pkg/libp2p
import pkg/chronos
import pkg/taskpools
import pkg/codex/codextypes
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/slots

import ../../asynctest

type CountingStore* = ref object of NetworkStore
  lookups*: Table[Cid, int]

proc new*(T: type CountingStore,
  engine: BlockExcEngine, localStore: BlockStore): CountingStore =
  # XXX this works cause NetworkStore.new is trivial
  result = CountingStore(engine: engine, localStore: localStore)

method getBlock*(self: CountingStore,
  address: BlockAddress): Future[?!Block] {.async.} =

  self.lookups.mgetOrPut(address.cid, 0).inc
  await procCall getBlock(NetworkStore(self), address)

proc toTimesDuration*(d: chronos.Duration): times.Duration =
  initDuration(seconds = d.seconds)

proc drain*(
  stream: LPStream | Result[lpstream.LPStream, ref CatchableError]):
  Future[seq[byte]] {.async.} =

  let
    stream =
      when typeof(stream) is Result[lpstream.LPStream, ref CatchableError]:
        stream.tryGet()
      else:
        stream

  defer:
    await stream.close()

  var data: seq[byte]
  while not stream.atEof:
    var
      buf = newSeq[byte](DefaultBlockSize.int)
      res = await stream.readOnce(addr buf[0], DefaultBlockSize.int)
    check res <= DefaultBlockSize.int
    buf.setLen(res)
    data &= buf

  data

proc pipeChunker*(stream: BufferStream, chunker: Chunker) {.async.} =
  try:
    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):
      await stream.pushData(chunk)
  finally:
    await stream.pushEof()
    await stream.close()

template setupAndTearDown*() {.dirty.} =
  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    clock: Clock
    localStore: RepoStore
    localStoreRepoDs: DataStore
    localStoreMetaDs: DataStore
    engine: BlockExcEngine
    store: NetworkStore
    node: CodexNodeRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    discovery: DiscoveryEngine
    advertiser: Advertiser
    taskpool: Taskpool

  let
    path = currentSourcePath().parentDir
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

  setup:
    file = open(path /../ "" /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)

    clock = SystemClock.new()
    localStoreMetaDs = metaTmp.newDb()
    localStoreRepoDs = repoTmp.newDb()
    localStore = RepoStore.new(localStoreRepoDs, localStoreMetaDs, clock = clock)
    await localStore.start()

    blockDiscovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0")
        .expect("Should return multiaddress")])
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
    advertiser = Advertiser.new(localStore, blockDiscovery)
    engine = BlockExcEngine.new(localStore, wallet, network, discovery, advertiser, peerStore, pendingBlocks)
    store = NetworkStore.new(engine, localStore)
    taskpool = Taskpool.new(num_threads = countProcessors())
    node = CodexNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      prover = Prover.none,
      discovery = blockDiscovery,
      taskpool = taskpool)

  teardown:
    close(file)
    await node.stop()
    await metaTmp.destroyDb()
    await repoTmp.destroyDb()
