## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/questionable/results
import pkg/codex/blocktype as bt
import pkg/codex/stores/repostore
import pkg/codex/clock

import ../../asynctest
import ../helpers
import ../helpers/mocktimer
import ../helpers/mockrepostore
import ../helpers/mockclock
import ../examples

import codex/stores/maintenance

checksuite "BlockMaintainer":
  var mockRepoStore: MockRepoStore
  var interval: Duration
  var mockTimer: MockTimer
  var mockClock: MockClock

  var blockMaintainer: BlockMaintainer

  var testBe1: BlockExpiration
  var testBe2: BlockExpiration
  var testBe3: BlockExpiration

  proc createTestExpiration(expiry: SecondsSince1970): BlockExpiration =
    BlockExpiration(
      cid: bt.Block.example.cid,
      expiry: expiry
    )

  setup:
    mockClock = MockClock.new()
    mockClock.set(100)

    testBe1 = createTestExpiration(200)
    testBe2 = createTestExpiration(300)
    testBe3 = createTestExpiration(400)

    mockRepoStore = MockRepoStore.new()
    mockRepoStore.testBlockExpirations.add(testBe1)
    mockRepoStore.testBlockExpirations.add(testBe2)
    mockRepoStore.testBlockExpirations.add(testBe3)

    interval = 1.days
    mockTimer = MockTimer.new()

    blockMaintainer = BlockMaintainer.new(
      mockRepoStore,
      interval,
      numberOfBlocksPerInterval = 2,
      mockTimer,
      mockClock)

  test "Start should start timer at provided interval":
    blockMaintainer.start()
    check mockTimer.startCalled == 1
    check mockTimer.mockInterval == interval

  test "Stop should stop timer":
    await blockMaintainer.stop()
    check mockTimer.stopCalled == 1

  test "Timer callback should call getBlockExpirations on RepoStore":
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.getBeMaxNumber == 2
      mockRepoStore.getBeOffset == 0

  test "Timer callback should handle Catachable errors":
    mockRepoStore.getBlockExpirationsThrows = true
    blockMaintainer.start()
    await mockTimer.invokeCallback()

  test "Subsequent timer callback should call getBlockExpirations on RepoStore with offset":
    blockMaintainer.start()
    await mockTimer.invokeCallback()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.getBeMaxNumber == 2
      mockRepoStore.getBeOffset == 2

  test "Timer callback should delete no blocks if none are expired":
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.delBlockCids.len == 0

  test "Timer callback should delete one block if it is expired":
    mockClock.set(250)
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.delBlockCids == [testBe1.cid]

  test "Timer callback should delete multiple blocks if they are expired":
    mockClock.set(500)
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.delBlockCids == [testBe1.cid, testBe2.cid]

  test "After deleting a block, subsequent timer callback should decrease offset by the number of deleted blocks":
    mockClock.set(250)
    blockMaintainer.start()
    await mockTimer.invokeCallback()

    check mockRepoStore.delBlockCids == [testBe1.cid]

    # Because one block was deleted, the offset used in the next call should be 2 minus 1.
    await mockTimer.invokeCallback()

    check:
      mockRepoStore.getBeMaxNumber == 2
      mockRepoStore.getBeOffset == 1

  test "Should delete all blocks if expired, in two timer callbacks":
    mockClock.set(500)
    blockMaintainer.start()
    await mockTimer.invokeCallback()
    await mockTimer.invokeCallback()

    check mockRepoStore.delBlockCids == [testBe1.cid, testBe2.cid, testBe3.cid]

  test "Iteration offset should loop":
    blockMaintainer.start()
    await mockTimer.invokeCallback()
    check mockRepoStore.getBeOffset == 0

    await mockTimer.invokeCallback()
    check mockRepoStore.getBeOffset == 2

    await mockTimer.invokeCallback()
    check mockRepoStore.getBeOffset == 0

  test "Should handle new blocks":
    proc invokeTimerManyTimes(): Future[void] {.async.} =
      for i in countup(0, 10):
        await mockTimer.invokeCallback()

    blockMaintainer.start()
    await invokeTimerManyTimes()

    # no blocks have expired
    check mockRepoStore.delBlockCids == []

    mockClock.set(250)
    await invokeTimerManyTimes()
    # one block has expired
    check mockRepoStore.delBlockCids == [testBe1.cid]

    # new blocks are added
    let testBe4 = createTestExpiration(600)
    let testBe5 = createTestExpiration(700)
    mockRepoStore.testBlockExpirations.add(testBe4)
    mockRepoStore.testBlockExpirations.add(testBe5)

    mockClock.set(500)
    await invokeTimerManyTimes()
    # All blocks have expired
    check mockRepoStore.delBlockCids == [testBe1.cid, testBe2.cid, testBe3.cid]

    mockClock.set(650)
    await invokeTimerManyTimes()
    # First new block has expired
    check mockRepoStore.delBlockCids == [testBe1.cid, testBe2.cid, testBe3.cid, testBe4.cid]

    mockClock.set(750)
    await invokeTimerManyTimes()
    # Second new block has expired
    check mockRepoStore.delBlockCids == [testBe1.cid, testBe2.cid, testBe3.cid, testBe4.cid, testBe5.cid]
