import std/times
import pkg/chronos
import codex/clock

export clock

type
  MockClock* = ref object of Clock
    time: SecondsSince1970
    waiting: seq[Waiting]

  Waiting = ref object
    until: SecondsSince1970
    future: Future[void]

func new*(_: type MockClock, time: SecondsSince1970 = getTime().toUnix): MockClock =
  ## Create a mock clock instance
  MockClock(time: time)

proc set*(clock: MockClock, time: SecondsSince1970) =
  clock.time = time
  var index = 0
  while index < clock.waiting.len:
    if clock.waiting[index].until <= clock.time:
      clock.waiting[index].future.complete()
      clock.waiting.del(index)
    else:
      inc index

proc advance*(clock: MockClock, seconds: int64) =
  clock.set(clock.time + seconds)

method now*(clock: MockClock): SecondsSince1970 =
  clock.time

method waitUntil*(clock: MockClock, time: SecondsSince1970) {.async.} =
  if time > clock.now():
    let future = newFuture[void]()
    clock.waiting.add(Waiting(until: time, future: future))
    await future

proc isWaiting*(clock: MockClock): bool =
  clock.waiting.len > 0
