import pkg/codex/streams/storestream
import std/unittest

# From lip2p/tests/helpers
const trackerNames = [StoreStreamTrackerName]

iterator testTrackers*(extras: openArray[string] = []): TrackerBase =
  for name in trackerNames:
    let t = getTracker(name)
    if not isNil(t):
      yield t
  for name in extras:
    let t = getTracker(name)
    if not isNil(t):
      yield t

proc checkTracker*(name: string) =
  var tracker = getTracker(name)
  if tracker.isLeaked():
    checkpoint tracker.dump()
    fail()

proc checkTrackers*() =
  for tracker in testTrackers():
    if tracker.isLeaked():
      checkpoint tracker.dump()
      fail()
  try:
    GC_fullCollect()
  except:
    discard
