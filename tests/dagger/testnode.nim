import std/os
import std/options

import pkg/asynctest
import pkg/chronos
import pkg/chronicles
import pkg/stew/byteutils

import pkg/nitro
import pkg/libp2p

import pkg/dagger/stores
import pkg/dagger/blockexchange
import pkg/dagger/chunker
import pkg/dagger/node
import pkg/dagger/manifest
import pkg/dagger/blocktype as bt
import pkg/dagger/erasure

import ./helpers

suite "Test Node":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    localStore: CacheStore
    engine: BlockExcEngine
    store: NetworkStore
    erasure: Erasure
    node: DaggerNodeRef

  setup:
    file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = BlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)
    localStore = CacheStore.new(cacheSize = (file.getFileSize * 5), chunkSize = BlockSize)
    engine = BlockExcEngine.new(localStore, wallet, network)
    store = NetworkStore.new(engine, localStore)
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    node = DaggerNodeRef.new(switch, store, engine, erasure)

    await node.start()

  teardown:
    close(file)
    await node.stop()

  test "Store Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)

    var
      manifest = Manifest.new().tryGet()

    try:
      while (
        let chunk = await chunker.getBytes();
        chunk.len > 0):
        await stream.pushData(chunk)
        manifest.add(bt.Block.new(chunk).tryGet().cid)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()

    check:
      manifestCid in localStore

    var
      manifestBlock = (await localStore.getBlock(manifestCid)).tryGet()
      localManifest = Manifest.decode(manifestBlock.data).tryGet()

    check:
      manifest.len == localManifest.len
      manifest.cid == localManifest.cid

  test "Retrieve Data Stream":
    var
      manifest = Manifest.new().tryGet()
      original: seq[byte]

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let
        blk = bt.Block.new(chunk).tryGet()

      original &= chunk
      check await localStore.putBlock(blk)
      manifest.add(blk.cid)

    let
      manifestBlock = bt.Block.new(
        manifest.encode().tryGet(),
        codec = DagPBCodec)
        .tryGet()

    check await localStore.putBlock(manifestBlock)

    let stream = (await node.retrieve(manifestBlock.cid)).tryGet()
    var data: seq[byte]
    while not stream.atEof:
      var
        buf = newSeq[byte](BlockSize)
        res = await stream.readOnce(addr buf[0], BlockSize div 2)

      buf.setLen(res)

      data &= buf

    check data == original

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.new(testString.toBytes).tryGet()

    check (await localStore.putBlock(blk))
    let stream = (await node.retrieve(blk.cid)).tryGet()

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString

  test "Request storage":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)

    var
      manifest = Manifest.new().tryGet()

    try:
      while (
        let chunk = await chunker.getBytes();
        chunk.len > 0):
        await stream.pushData(chunk)
        manifest.add(bt.Block.new(chunk).tryGet().cid)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()
      requestCid = (await node.requestStorage(manifestCid, 100, 1.weeks, 20, 10)).tryGet()
