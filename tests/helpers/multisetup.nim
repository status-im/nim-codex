import pkg/chronos

# Allow multiple setups and teardowns in a test suite
template asyncmultisetup* =
  var setups: seq[proc: Future[void].Raising([AsyncExceptionError]) {.gcsafe.}]
  var teardowns: seq[
    proc: Future[void].Raising([AsyncExceptionError]) {.gcsafe.}]

  setup:
    for setup in setups:
      await setup()

  teardown:
    for teardown in teardowns:
      await teardown()

  template setup(setupBody) {.inject, used.} =
    setups.add(proc {.async: (
      handleException: true, raises: [AsyncExceptionError]).} = setupBody)

  template teardown(teardownBody) {.inject, used.} =
    teardowns.insert(proc {.async: (
      handleException: true, raises: [AsyncExceptionError]).} = teardownBody)

template multisetup* =
  var setups: seq[proc() {.gcsafe.}]
  var teardowns: seq[proc() {.gcsafe.}]

  setup:
    for setup in setups:
      setup()

  teardown:
    for teardown in teardowns:
      teardown()

  template setup(setupBody) {.inject, used.} =
    let setupProc = proc = setupBody
    setups.add(setupProc)

  template teardown(teardownBody) {.inject, used.} =
    teardowns.insert(proc = teardownBody)
