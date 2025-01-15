import std/strutils

import pkg/chronos
import pkg/stew/byteutils
import pkg/questionable/results
import pkg/codex/stores/cachestore
import pkg/codex/chunker

import ./commonstoretests

import ../../asynctest
import ../helpers

checksuite "Cache Store":
  var
    newBlock, newBlock1, newBlock2, newBlock3: Block
    store: CacheStore

  setup:
    newBlock = Block.new("New Kids on the Block".toBytes()).tryGet()
    newBlock1 = Block.new("1".repeat(100).toBytes()).tryGet()
    newBlock2 = Block.new("2".repeat(100).toBytes()).tryGet()
    newBlock3 = Block.new("3".repeat(100).toBytes()).tryGet()
    store = CacheStore.new()

  test "constructor":
    # cache size cannot be smaller than chunk size
    expect ValueError:
      discard CacheStore.new(cacheSize = 1, chunkSize = 2)

    store = CacheStore.new(cacheSize = 100, chunkSize = 1)
    check store.currentSize == 0'nb

    store = CacheStore.new(@[newBlock1, newBlock2, newBlock3])
    check store.currentSize == 300'nb

    # initial cache blocks total more than cache size, currentSize should
    # never exceed max cache size
    store = CacheStore.new(
      blocks = @[newBlock1, newBlock2, newBlock3], cacheSize = 200, chunkSize = 1
    )
    check store.currentSize == 200'nb

    # cache size cannot be less than chunks size
    expect ValueError:
      discard CacheStore.new(cacheSize = 99, chunkSize = 100)

  test "putBlock":
    (await store.putBlock(newBlock1)).tryGet()
    check (await store.hasBlock(newBlock1.cid)).tryGet()

    # block size bigger than entire cache
    store = CacheStore.new(cacheSize = 99, chunkSize = 98)
    (await store.putBlock(newBlock1)).tryGet()
    check not (await store.hasBlock(newBlock1.cid)).tryGet()

    # block being added causes removal of LRU block
    store =
      CacheStore.new(@[newBlock1, newBlock2, newBlock3], cacheSize = 200, chunkSize = 1)
    check:
      not (await store.hasBlock(newBlock1.cid)).tryGet()
      (await store.hasBlock(newBlock2.cid)).tryGet()
      (await store.hasBlock(newBlock2.cid)).tryGet()
      store.currentSize.int == newBlock2.data.len + newBlock3.data.len # 200

commonBlockStoreTests(
  "Cache",
  proc(): BlockStore =
    BlockStore(CacheStore.new(cacheSize = 1000, chunkSize = 1)),
)
