import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/datastore

import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/clock
import pkg/codex/utils/asynciter

import ../../asynctest
import ../helpers
import ../helpers/mockclock
import ../examples
import ./commonstoretests

checksuite "Test RepoStore start/stop":

  var
    repoDs: Datastore
    metaDs: Datastore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()

  test "Should set started flag once started":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    check repo.started

  test "Should set started flag to false once stopped":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.stop()
    check not repo.started

  test "Should allow start to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.start()
    check repo.started

  test "Should allow stop to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.stop()
    await repo.stop()
    check not repo.started

asyncchecksuite "RepoStore":
  var
    repoDs: Datastore
    metaDs: Datastore
    mockClock: MockClock

    repo: RepoStore

  let
    now: SecondsSince1970 = 123

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)

    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 200'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet

  proc createTestBlock(size: int): bt.Block =
    bt.Block.new('a'.repeat(size).toBytes).tryGet()

  test "Should update current used bytes on block put":
    let blk = createTestBlock(200)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet

    check:
      repo.quotaUsedBytes == 200'nb

  test "Should update current used bytes on block delete":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    (await repo.delBlock(blk.cid)).tryGet

    check:
      repo.quotaUsedBytes == 0'nb

  test "Should not update current used bytes if block exist":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    # put again
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

  test "Should fail storing passed the quota":
    let blk = createTestBlock(300)

    check repo.totalUsed == 0'nb
    expect QuotaNotEnoughError:
      (await repo.putBlock(blk)).tryGet

  test "Should reserve bytes":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100'nb

    (await repo.reserve(100'nb)).tryGet

    check:
      repo.totalUsed == 200'nb
      repo.quotaUsedBytes == 100'nb
      repo.quotaReservedBytes == 100'nb

  test "Should not reserve bytes over max quota":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100'nb

    expect QuotaNotEnoughError:
      (await repo.reserve(101'nb)).tryGet

    check:
      repo.totalUsed == 100'nb
      repo.quotaUsedBytes == 100'nb
      repo.quotaReservedBytes == 0'nb

  test "Should release bytes":
    discard createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.reserve(100'nb)).tryGet
    check repo.totalUsed == 100'nb

    (await repo.release(100'nb)).tryGet

    check:
      repo.totalUsed == 0'nb
      repo.quotaUsedBytes == 0'nb
      repo.quotaReservedBytes == 0'nb

  test "Should not release bytes less than quota":
    check repo.totalUsed == 0'nb
    (await repo.reserve(100'nb)).tryGet
    check repo.totalUsed == 100'nb

    expect RangeDefect:
      (await repo.release(101'nb)).tryGet

    check:
      repo.totalUsed == 100'nb
      repo.quotaUsedBytes == 0'nb
      repo.quotaReservedBytes == 100'nb

  proc getExpirations(): Future[seq[BlockExpiration]] {.async.} =
    let iter = (await repo.getBlockExpirations(100, 0)).tryGet()

    var res = newSeq[BlockExpiration]()
    for fut in iter:
      let be = await fut
      res.add(be)

    res

  test "Should store block expiration timestamp":
    let
      duration = 10.seconds
      blk = createTestBlock(100)

    let
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)

    (await repo.putBlock(blk, duration.some)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

  test "Should store block with default expiration timestamp when not provided":
    let
      blk = createTestBlock(100)

    let
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + DefaultBlockTtl.seconds)

    (await repo.putBlock(blk)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

  test "Should refuse update expiry with negative timestamp":
    let
      blk = createTestBlock(100)
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)

    (await repo.putBlock(blk, some 10.seconds)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

    expect ValueError:
      (await repo.ensureExpiry(blk.cid, -1)).tryGet

    expect ValueError:
      (await repo.ensureExpiry(blk.cid, 0)).tryGet

  test "Should fail when updating expiry of non-existing block":
    let
      blk = createTestBlock(100)

    expect BlockNotFoundError:
      (await repo.ensureExpiry(blk.cid, 10)).tryGet

  test "Should update block expiration timestamp when new expiration is farther":
    let
      blk = createTestBlock(100)
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)
      updatedExpectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 20)

    (await repo.putBlock(blk, some 10.seconds)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

    (await repo.ensureExpiry(blk.cid, now + 20)).tryGet

    let updatedExpirations = await getExpirations()

    check:
      expectedExpiration notin updatedExpirations
      updatedExpectedExpiration in updatedExpirations

  test "Should not update block expiration timestamp when current expiration is farther then new one":
    let
      blk = createTestBlock(100)
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)
      updatedExpectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 5)

    (await repo.putBlock(blk, some 10.seconds)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

    (await repo.ensureExpiry(blk.cid, now + 5)).tryGet

    let updatedExpirations = await getExpirations()

    check:
      expectedExpiration in updatedExpirations
      updatedExpectedExpiration notin updatedExpirations

  test "delBlock should remove expiration metadata":
    let
      blk = createTestBlock(100)
      expectedKey = Key.init("meta/ttl/" & $blk.cid).tryGet

    (await repo.putBlock(blk, 10.seconds.some)).tryGet
    (await repo.delBlock(blk.cid)).tryGet

    let expirations = await getExpirations()

    check:
      expirations.len == 0

  test "Should retrieve block expiration information":
    proc unpack(beIter: Future[?!AsyncIter[BlockExpiration]]): Future[seq[BlockExpiration]] {.async.} =
      var expirations = newSeq[BlockExpiration](0)
      without iter =? (await beIter), err:
        return expirations
      for beFut in toSeq(iter):
        let value = await beFut
        expirations.add(value)
      return expirations

    let
      duration = 10.seconds
      blk1 = createTestBlock(10)
      blk2 = createTestBlock(11)
      blk3 = createTestBlock(12)

    let
      expectedExpiration: SecondsSince1970 = now + 10

    proc assertExpiration(be: BlockExpiration, expectedBlock: bt.Block) =
      check:
        be.cid == expectedBlock.cid
        be.expiry == expectedExpiration


    (await repo.putBlock(blk1, duration.some)).tryGet
    (await repo.putBlock(blk2, duration.some)).tryGet
    (await repo.putBlock(blk3, duration.some)).tryGet

    let
      blockExpirations1 = await unpack(repo.getBlockExpirations(maxNumber=2, offset=0))
      blockExpirations2 = await unpack(repo.getBlockExpirations(maxNumber=2, offset=2))

    check blockExpirations1.len == 2
    assertExpiration(blockExpirations1[0], blk2)
    assertExpiration(blockExpirations1[1], blk1)

    check blockExpirations2.len == 1
    assertExpiration(blockExpirations2[0], blk3)

  test "should put empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.putBlock(blk)).isOk

  test "should get empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()

    let got = await repo.getBlock(blk.cid)
    check got.isOk
    check got.get.cid == blk.cid

  test "should delete empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.delBlock(blk.cid)).isOk

  test "should have empty block":
    let blk = Cid.example.emptyBlock.tryGet()

    let has = await repo.hasBlock(blk.cid)
    check has.isOk
    check has.get

commonBlockStoreTests(
  "RepoStore Sql backend", proc: BlockStore =
    BlockStore(
      RepoStore.new(
        SQLiteDatastore.new(Memory).tryGet(),
        SQLiteDatastore.new(Memory).tryGet(),
        clock = MockClock.new())))

const
  path = currentSourcePath().parentDir / "test"

proc before() {.async.} =
  createDir(path)

proc after() {.async.} =
  os.removeDir(path)

let
  depth = path.split(os.DirSep).len

commonBlockStoreTests(
  "RepoStore FS backend", proc: BlockStore =
    BlockStore(
      RepoStore.new(
        FSDatastore.new(path, depth).tryGet(),
        SQLiteDatastore.new(Memory).tryGet(),
        clock = MockClock.new())),
  before = before,
  after = after)
