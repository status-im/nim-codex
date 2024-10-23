import std/sequtils
import std/strutils
import std/options

import pkg/chronos
import pkg/libp2p/multicodec
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/manifest
import pkg/codex/merkletree
import pkg/codex/utils

import ../../asynctest
import ../helpers
import ../examples

type
  StoreProvider* = proc(): BlockStore {.gcsafe.}
  Before* = proc(): Future[void] {.gcsafe.}
  After* = proc(): Future[void] {.gcsafe.}

proc commonBlockStoreTests*(name: string,
                            provider: StoreProvider,
                            before: Before = nil,
                            after: After = nil) =

  asyncchecksuite name & " Store Common":
    var
      newBlock, newBlock1, newBlock2, newBlock3: Block
      manifest: Manifest
      tree: CodexTree
      store: BlockStore

    setup:
      newBlock = Block.new("New Kids on the Block".toBytes()).tryGet()
      newBlock1 = Block.new("1".repeat(100).toBytes()).tryGet()
      newBlock2 = Block.new("2".repeat(100).toBytes()).tryGet()
      newBlock3 = Block.new("3".repeat(100).toBytes()).tryGet()

      (manifest, tree) = makeManifestAndTree(@[newBlock, newBlock1, newBlock2, newBlock3]).tryGet()

      if not isNil(before):
        await before()

      store = provider()

    teardown:
      await store.close()

      if not isNil(after):
        await after()

    test "putBlock":
      (await store.putBlock(newBlock1)).tryGet()
      check (await store.hasBlock(newBlock1.cid)).tryGet()

    test "putBlock raises onBlockStored":
      var storedCid = Cid.example
      proc onStored(cid: Cid) {.async.} = 
        storedCid = cid
      store.onBlockStored = onStored.some()

      (await store.putBlock(newBlock1)).tryGet()

      check storedCid == newBlock1.cid

    test "getBlock":
      (await store.putBlock(newBlock)).tryGet()
      let blk = await store.getBlock(newBlock.cid)
      check blk.tryGet() == newBlock

    test "fail getBlock":
      expect BlockNotFoundError:
        discard (await store.getBlock(newBlock.cid)).tryGet()

    test "hasBlock":
      (await store.putBlock(newBlock)).tryGet()

      check:
        (await store.hasBlock(newBlock.cid)).tryGet()
        await newBlock.cid in store

    test "fail hasBlock":
      check:
        not (await store.hasBlock(newBlock.cid)).tryGet()
        not (await newBlock.cid in store)

    test "delBlock":
      (await store.putBlock(newBlock1)).tryGet()
      check (await store.hasBlock(newBlock1.cid)).tryGet()

      (await store.delBlock(newBlock1.cid)).tryGet()

      check not (await store.hasBlock(newBlock1.cid)).tryGet()

    test "listBlocks Blocks":
      let
        blocks = @[newBlock1, newBlock2, newBlock3]

        putHandles = await allFinished(
          blocks.mapIt( store.putBlock( it ) ))

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOk

      let
        cids = (await store.listBlocks(blockType = BlockType.Block)).tryGet()

      var count = 0
      for c in cids:
        if cid =? await c:
          check (await store.hasBlock(cid)).tryGet()
          count.inc

      check count == 3

    test "listBlocks Manifest":
      let
        blocks = @[newBlock1, newBlock2, newBlock3]
        manifestBlock = Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
        treeBlock = Block.new(tree.encode()).tryGet()
        putHandles = await allFinished(
         (@[treeBlock, manifestBlock] & blocks).mapIt( store.putBlock( it ) ))

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOk

      let
        cids = (await store.listBlocks(blockType = BlockType.Manifest)).tryGet()

      var count = 0
      for c in cids:
        if cid =? (await c):
          check manifestBlock.cid == cid
          check (await store.hasBlock(cid)).tryGet()
          count.inc

      check count == 1

    test "listBlocks Both":
      let
        blocks = @[newBlock1, newBlock2, newBlock3]
        manifestBlock = Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
        treeBlock = Block.new(tree.encode()).tryGet()
        putHandles = await allFinished(
         (@[treeBlock, manifestBlock] & blocks).mapIt( store.putBlock( it ) ))

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOk

      let
        cids = (await store.listBlocks(blockType = BlockType.Both)).tryGet()

      var count = 0
      for c in cids:
        if cid =? (await c):
          check (await store.hasBlock(cid)).tryGet()
          count.inc

      check count == 5
