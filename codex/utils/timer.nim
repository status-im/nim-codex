## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Timer
## Used to execute a callback in a loop

import pkg/upraises

push:
  {.upraises: [].}

import pkg/chronos

import ../logutils

type
  TimerCallback* = proc(): Future[void] {.gcsafe, upraises: [].}
  Timer* = ref object of RootObj
    callback: TimerCallback
    interval: Duration
    name: string
    loopFuture: Future[void]

proc new*(T: type Timer, timerName = "Unnamed Timer"): Timer =
  ## Create a new Timer intance with the given name
  Timer(name: timerName)

proc timerLoop(timer: Timer) {.async: (raises: []).} =
  try:
    while true:
      await timer.callback()
      await sleepAsync(timer.interval)
  except CancelledError:
    discard # do not propagate as timerLoop is asyncSpawned
  except CatchableError as exc:
    error "Timer caught unhandled exception: ", name = timer.name, msg = exc.msg

method start*(
    timer: Timer, callback: TimerCallback, interval: Duration
) {.gcsafe, base.} =
  if timer.loopFuture != nil:
    return
  trace "Timer starting: ", name = timer.name
  timer.callback = callback
  timer.interval = interval
  timer.loopFuture = timerLoop(timer)
  asyncSpawn timer.loopFuture

method stop*(timer: Timer) {.async, base.} =
  if timer.loopFuture != nil and not timer.loopFuture.finished:
    trace "Timer stopping: ", name = timer.name
    await timer.loopFuture.cancelAndWait()
    timer.loopFuture = nil
