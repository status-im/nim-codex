## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos

import codex/utils/timer

type MockTimer* = ref object of Timer
  startCalled*: int
  stopCalled*: int
  mockInterval*: Duration
  mockCallback: timer.TimerCallback

proc new*(T: type MockTimer): MockTimer =
  ## Create a mocked Timer instance
  MockTimer(startCalled: 0, stopCalled: 0)

method start*(mockTimer: MockTimer, callback: timer.TimerCallback, interval: Duration) =
  mockTimer.mockCallback = callback
  mockTimer.mockInterval = interval
  inc mockTimer.startCalled

method stop*(mockTimer: MockTimer) {.async.} =
  inc mockTimer.stopCalled

method invokeCallback*(mockTimer: MockTimer) {.async, base.} =
  await mockTimer.mockCallback()
