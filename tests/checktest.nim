import ./helpers

## Unit testing suite that calls checkTrackers in teardown to check for memory leaks using chronos trackers.
template checksuite*(name, body) =
  suite name:
    proc suiteProc() =
      multisetup()

      teardown:
        checkTrackers()

      body

    suiteProc()

template asyncchecksuite*(name, body) =
  suite name:
    proc suiteProc() =
      asyncmultisetup()

      teardown:
        checkTrackers()

      body

    suiteProc()

export helpers
