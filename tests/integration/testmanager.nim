import std/os
import std/strformat
import pkg/chronos
import pkg/chronos/asyncproc
import pkg/codex/utils/exceptions
import pkg/codex/logutils
import pkg/questionable
import pkg/questionable/results
import ./hardhatprocess
import ./utils
import ../examples

type
  TestManager* = ref object
    configs: seq[IntegrationTestConfig]
    tests: seq[IntegrationTest]
    hardhats: seq[HardhatProcess]
    lastHardhatPort: int
    lastCodexApiPort: int
    lastCodexDiscPort: int
    debugTestHarness: bool # output chronicles logs for the manager and multinodes harness
    debugHardhat: bool
    timeStart: Moment
    timeEnd: Moment
    codexPortLock: AsyncLock
    hardhatPortLock: AsyncLock

  IntegrationTestConfig* = object
    startHardhat*: bool
    testFile*: string
    name*: string

  IntegrationTest = ref object
    config: IntegrationTestConfig
    process: Future[CommandExResponse].Raising([AsyncProcessError, AsyncProcessTimeoutError, CancelledError])
    timeStart: Moment
    timeEnd: Moment
    output: ?!CommandExResponse
    testId: string    # when used in datadir path, prevents data dir clashes

  TestManagerError = object of CatchableError

{.push raises: [].}

logScope:
  topics = "testing integration testmanager"

func new*(
  _: type TestManager,
  configs: seq[IntegrationTestConfig],
  debugTestHarness = false,
  debugHardhat = false): TestManager =

  TestManager(
    configs: configs,
    lastHardhatPort: 8545,
    lastCodexApiPort: 8000,
    lastCodexDiscPort: 9000,
    debugTestHarness: debugTestHarness,
    debugHardhat: debugHardhat
  )

proc raiseTestManagerError(msg: string, parent: ref CatchableError = nil) {.raises: [TestManagerError].} =
  raise newException(TestManagerError, msg, parent)

template withLock*(lock: AsyncLock, body: untyped) =
  if lock.isNil:
    lock = newAsyncLock()

  await lock.acquire()
  try:
    body
    await sleepAsync(1.millis)
  finally:
    try:
      lock.release()
    except AsyncLockError as e:
      raiseAssert "failed to release lock, error: " & e.msg

proc startHardhat(
  manager: TestManager,
  config: IntegrationTestConfig): Future[int] {.async: (raises: [CancelledError, TestManagerError]).} =

  var args: seq[string] = @[]
  var port: int

  withLock(manager.hardhatPortLock):
    port = await nextFreePort(manager.lastHardhatPort + 10)
    manager.lastHardhatPort = port

  args.add("--port")
  args.add($port)

  trace "starting hardhat process on port ", port
  try:
    let node = await HardhatProcess.startNode(
      args,
      manager.debugHardhat,
      "hardhat for '" & config.name & "'")
    await node.waitUntilStarted()
    manager.hardhats.add node
    return port
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raiseTestManagerError "hardhat node failed to start: " & e.msg, e

proc printOutput(manager: TestManager, test: IntegrationTest) =
  without output =? test.output, error:
    echo "[FATAL] Test '", test.config.name, "' failed to run to completion"
    echo "    Error: ", error.msg
    echo "    Stacktrace: ", error.getStackTrace()
    return

  if output.status != 0:
    if manager.debugTestHarness:
      echo output.stdError
    echo output.stdOutput
    echo "[FAILED] Test '", test.config.name, "' failed"

  else:
    echo output.stdOutput
    echo "[OK] Test '", test.config.name, "' succeeded"

proc runTest(manager: TestManager, config: IntegrationTestConfig) {.async: (raises: [CancelledError]).} =
  logScope:
    config

  trace "Running test"

  var test = IntegrationTest(
    config: config,
    testId: $ uint16.example
  )

  var hardhatPort = 0
  if config.startHardhat:
    try:
      hardhatPort = await manager.startHardhat(config)
    except TestManagerError as e:
      e.msg = "Failed to start hardhat: " & e.msg
      test.output = CommandExResponse.failure(e)

  var apiPort, discPort: int
  withLock(manager.codexPortLock):
    # inc by 20 to allow each test to run 20 codex nodes (clients, SPs,
    # validators) giving a good chance the port will be free
    apiPort = await nextFreePort(manager.lastCodexApiPort + 20)
    manager.lastCodexApiPort = apiPort
    discPort = await nextFreePort(manager.lastCodexDiscPort + 20)
    manager.lastCodexDiscPort = discPort

  var logging = ""
  if manager.debugTestHarness:
    logging = "-d:chronicles_log_level=TRACE " &
              "-d:chronicles_disabled_topics=websock " &
              "-d:chronicles_default_output_device=stdout " &
              "-d:chronicles_sinks=textlines"

  var testFile: string
  try:
    testFile = absolutePath(
                config.testFile,
                root = currentSourcePath().parentDir().parentDir())
  except ValueError as e:
    raiseAssert "bad file name, testFile: " & config.testFile & ", error: " & e.msg

  var command: string
  try:
    withLock(manager.hardhatPortLock):
      command =  "nim c " &
                &"-d:CodexApiPort={apiPort} " &
                &"-d:CodexDiscPort={discPort} " &
                (if config.startHardhat:
                  &"-d:HardhatPort={hardhatPort} "
                else: "") &
                &"-d:TestId={test.testId} " &
                &"{logging} " &
                "--verbosity:0 " &
                "--hints:off " &
                "-d:release " &
                "-r " &
                &"{testFile}"
  except ValueError as e:
    raiseAssert "bad command" &
                ", apiPort: " & $apiPort &
                ", discPort: " & $discPort &
                ", logging: " & logging &
                ", testFile: " & testFile &
                ", error: " & e.msg
  trace "Starting parallel integration test", command

  test.timeStart = Moment.now()
  test.process = execCommandEx(
    command = command,
    # options = {AsyncProcessOption.StdErrToStdOut, AsyncProcessOption.EvalCommand},
    timeout = 60.minutes
  )
  manager.tests.add test

  try:
    test.output = success(await test.process) # waits on waitForExit
    test.timeEnd = Moment.now()
    # echo "[OK] Test '" & config.name & "' completed in ", test.timeEnd - test.timeStart
    info "Test completed", name = config.name, duration = test.timeEnd - test.timeStart
    manager.printOutput(test)
  except CancelledError as e:
    raise e
  except AsyncProcessTimeoutError as e:
    test.timeEnd = Moment.now()
    # echo "[TIMEOUT] Test '" & config.name & "' timed out in ", test.timeEnd - test.timeStart
    error "Test timed out", name = config.name, duration = test.timeEnd - test.timeStart
    test.output = CommandExResponse.failure(e)
    manager.printOutput(test)
  except AsyncProcessError as e:
    test.timeEnd = Moment.now()
    # echo "[FAILED] Test '" & config.name & "' failed in ", test.timeEnd - test.timeStart
    error "Test failed to complete", name = config.name,duration = test.timeEnd - test.timeStart
    test.output = CommandExResponse.failure(e)
    manager.printOutput(test)

proc runTests(manager: TestManager) {.async: (raises: [CancelledError]).} =
  var testFutures: seq[Future[void].Raising([CancelledError])]

  manager.timeStart = Moment.now()

  for config in manager.configs:
    testFutures.add manager.runTest(config)

  await allFutures testFutures

  manager.timeEnd = Moment.now()

proc printOutput(manager: TestManager) =
  var successes = 0
  echo "▢=====================================================================▢"
  echo "| TEST SUMMARY                                                        |"
  echo "|"
  for test in manager.tests:
    without output =? test.output:
      echo "| [FATAL] Test '", test.config.name, "' failed to run to completion"
      continue
    if output.status != 0:
      echo "| [FAILED] Test '", test.config.name, "' failed"
    else:
      echo "| [OK] Test '", test.config.name, "' succeeded"
      inc successes

  echo "|                                                                     |"
  echo "| PASSING                       : ", successes, " / ", manager.tests.len
  let totalDuration = manager.timeEnd - manager.timeStart
  echo "| TOTAL TIME                    : ", totalDuration
  var totalDurationSerial: Duration
  for test in manager.tests:
    totalDurationSerial += (test.timeEnd - test.timeStart)
  # estimated time saved as serial execution with a single hardhat instance
  # incurs less overhead
  echo "| EST TOTAL TIME IF RUN SERIALLY: ", totalDurationSerial
  echo "| EST TIME SAVED (ROUGH)        : ", totalDurationSerial - totalDuration
  echo "▢=====================================================================▢"

proc start*(manager: TestManager) {.async: (raises: [CancelledError]).} =
  await manager.runTests()
  manager.printOutput()

proc stop*(manager: TestManager) {.async: (raises: [CancelledError]).} =
  for test in manager.tests:
    if not test.process.isNil and not test.process.finished:
      await test.process.cancelAndWait()

  for hardhat in manager.hardhats:
    try:
      await hardhat.stop()
    except CatchableError as e:
      trace "failed to stop hardhat node", error = e.msg