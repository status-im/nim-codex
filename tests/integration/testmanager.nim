import std/os
import std/strformat
import std/terminal
from std/unicode import toUpper
import std/unittest
import pkg/chronos
import pkg/chronos/asyncproc
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
    debugCodexNodes: bool # output chronicles logs for the codex nodes running in the tests
    timeStart: Moment
    timeEnd: Moment
    codexPortLock: AsyncLock
    hardhatPortLock: AsyncLock
    testTimeout: Duration # individual test timeout

  IntegrationTestConfig* = object
    startHardhat*: bool
    testFile*: string
    name*: string

  IntegrationTestStatus = enum ## The status of a test when it is done.
    Ok,       # tests completed and all succeeded
    Failed,   # tests completed, but one or more of the tests failed
    Timeout,  # the tests did not complete before the timeout
    Error     # the tests did not complete because an error occurred running the tests (usually an error in the harness)

  IntegrationTest = ref object
    config: IntegrationTestConfig
    process: Future[CommandExResponse].Raising([AsyncProcessError, AsyncProcessTimeoutError, CancelledError])
    timeStart: Moment
    timeEnd: Moment
    output: ?!CommandExResponse
    testId: string    # when used in datadir path, prevents data dir clashes
    status: IntegrationTestStatus

  TestManagerError = object of CatchableError

  Border {.pure.} = enum
    Left, Right
  Align {.pure.} = enum
    Left, Right

  MarkerPosition {.pure.} = enum
    Start,
    Finish

{.push raises: [].}

logScope:
  topics = "testing integration testmanager"

proc raiseTestManagerError(msg: string, parent: ref CatchableError = nil) {.raises: [TestManagerError].} =
  raise newException(TestManagerError, msg, parent)

proc new*(
  _: type TestManager,
  configs: seq[IntegrationTestConfig],
  debugTestHarness = false,
  debugHardhat = false,
  debugCodexNodes = false,
  testTimeout = 60.minutes): TestManager =

  TestManager(
    configs: configs,
    lastHardhatPort: 8545,
    lastCodexApiPort: 8000,
    lastCodexDiscPort: 9000,
    debugTestHarness: debugTestHarness,
    debugHardhat: debugHardhat,
    debugCodexNodes: debugCodexNodes,
    testTimeout: testTimeout
  )

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
    except AsyncLockError as parent:
      raiseTestManagerError "lock error", parent

template styledEcho*(args: varargs[untyped]) =
  try:
    styledEcho args
  except CatchableError as parent:
    raiseTestManagerError "failed to print to terminal, error: " & parent.msg, parent

proc duration(manager: TestManager): Duration =
  manager.timeEnd - manager.timeStart

proc duration(test: IntegrationTest): Duration =
  test.timeEnd - test.timeStart

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

proc printResult(
  test: IntegrationTest,
  colour: ForegroundColor) {.raises: [TestManagerError].} =

  styledEcho styleBright, colour, &"[{toUpper $test.status}] ",
            resetStyle, test.config.name,
            resetStyle, styleDim, &" ({test.duration})"

proc printOutputMarker(
  test: IntegrationTest,
  position: MarkerPosition,
  msg: string) {.raises: [TestManagerError].} =

  let newLine = if position == MarkerPosition.Start: "\n"
                else: ""

  styledEcho styleBright, bgWhite, fgBlack,
             &"{newLine}----- {toUpper $position} {test.config.name} {msg} -----"

proc printResult(
  test: IntegrationTest,
  processOutput = false,
  testHarnessErrors = false) {.raises: [TestManagerError].} =

  if test.status == IntegrationTestStatus.Error and
    error =? test.output.errorOption:
    test.printResult(fgRed)
    if testHarnessErrors:
      test.printOutputMarker(MarkerPosition.Start, "test harness errors")
      echo "Error during test execution: ", error.msg
      echo "Stacktrace: ", error.getStackTrace()
      test.printOutputMarker(MarkerPosition.Finish, "test harness errors")

  elif test.status == IntegrationTestStatus.Failed:
    if output =? test.output:
      if testHarnessErrors: #manager.debugTestHarness
        test.printOutputMarker(MarkerPosition.Start,
                                 "test harness errors (stderr)")
        echo output.stdError
        test.printOutputMarker(MarkerPosition.Finish,
                                 "test harness errors (stderr)")
      if processOutput:
        test.printOutputMarker(MarkerPosition.Start,
                                 "codex node output (stdout)")
        echo output.stdOutput
        test.printOutputMarker(MarkerPosition.Finish,
                                 "codex node output (stdout)")
    test.printResult(fgRed)

  elif test.status == IntegrationTestStatus.Timeout:
    test.printResult(fgYellow)

  elif test.status == IntegrationTestStatus.Ok:
    if processOutput and
       output =? test.output:
      test.printOutputMarker(MarkerPosition.Start,
                               "codex node output (stdout)")
      echo output.stdOutput
      test.printOutputMarker(MarkerPosition.Finish,
                               "codex node output (stdout)")
    test.printResult(fgGreen)

proc printSummary(test: IntegrationTest) {.raises: [TestManagerError].} =
  test.printResult(processOutput = false, testHarnessErrors = false)

proc printStart(test: IntegrationTest) {.raises: [TestManagerError].} =
  styledEcho styleBright, fgMagenta, &"[Integration test started] ", resetStyle, test.config.name

proc buildCommand(
  manager: TestManager,
  test: IntegrationTest,
  hardhatPort: int): Future[string] {.async: (raises:[CancelledError, TestManagerError]).} =

  var apiPort, discPort: int
  withLock(manager.codexPortLock):
    # TODO: needed? nextFreePort should take care of this
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
                test.config.testFile,
                root = currentSourcePath().parentDir().parentDir())
  except ValueError as parent:
    raiseTestManagerError "bad file name, testFile: " & test.config.testFile, parent

  var command: string
  withLock(manager.hardhatPortLock):
    try:
      return  "nim c " &
              &"-d:CodexApiPort={apiPort} " &
              &"-d:CodexDiscPort={discPort} " &
                (if test.config.startHardhat:
                  &"-d:HardhatPort={hardhatPort} "
                else: "") &
              &"-d:TestId={test.testId} " &
              &"{logging} " &
                "--verbosity:0 " &
                "--hints:off " &
                "-d:release " &
                "-r " &
              &"{testFile}"
    except ValueError as parent:
      raiseTestManagerError "bad command --\n" &
                              ", apiPort: " & $apiPort &
                              ", discPort: " & $discPort &
                              ", logging: " & logging &
                              ", testFile: " & testFile &
                              ", error: " & parent.msg,
                              parent

proc runTest(
  manager: TestManager,
  config: IntegrationTestConfig) {.async: (raises: [CancelledError, TestManagerError]).} =

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
      test.timeEnd = Moment.now()
      test.status = IntegrationTestStatus.Error
      test.output = CommandExResponse.failure(e)

  let command = await manager.buildCommand(test, hardhatPort)

  trace "Starting parallel integration test", command
  test.printStart()
  test.timeStart = Moment.now()
  test.process = execCommandEx(
    command = command,
    timeout = manager.testTimeout
  )
  manager.tests.add test

  try:

    let output = await test.process # waits on waitForExit
    test.output = success(output)
    test.timeEnd = Moment.now()

    info "Test completed", name = config.name, duration = test.timeEnd - test.timeStart

    if output.status != 0:
      test.status = IntegrationTestStatus.Failed
    else:
      test.status = IntegrationTestStatus.Ok

    test.printResult(processOutput = manager.debugCodexNodes,
                     testHarnessErrors = manager.debugTestHarness)

  except CancelledError as e:
    raise e

  except AsyncProcessTimeoutError as e:
    test.timeEnd = Moment.now()
    error "Test timed out", name = config.name, duration = test.timeEnd - test.timeStart
    test.output = CommandExResponse.failure(e)
    test.status = IntegrationTestStatus.Timeout
    test.printResult(processOutput = manager.debugCodexNodes,
                     testHarnessErrors = manager.debugTestHarness)

  except AsyncProcessError as e:
    test.timeEnd = Moment.now()
    error "Test failed to complete", name = config.name,duration = test.timeEnd - test.timeStart
    test.output = CommandExResponse.failure(e)
    test.status = IntegrationTestStatus.Error
    test.printResult(processOutput = manager.debugCodexNodes,
                     testHarnessErrors = manager.debugTestHarness)

proc runTests(manager: TestManager) {.async: (raises: [CancelledError, TestManagerError]).} =
  var testFutures: seq[Future[void].Raising([CancelledError, TestManagerError])]

  manager.timeStart = Moment.now()

  styledEcho styleBright, bgWhite, fgBlack,
             "\n[Integration Test Manager] Starting parallel integration tests"

  for config in manager.configs:
    testFutures.add manager.runTest(config)

  await allFutures testFutures

  manager.timeEnd = Moment.now()

proc withBorder(
  msg: string,
  align = Align.Left,
  width = 67,
  borders = {Border.Left, Border.Right}): string =

  if borders.contains(Border.Left):
    result &= "| "
  if align == Align.Left:
    result &= msg.alignLeft(width)
  elif align == Align.Right:
    result &= msg.align(width)
  if borders.contains(Border.Right):
    result &= " |"

proc printResult(manager: TestManager) {.raises: [TestManagerError].}=
  var successes = 0
  var totalDurationSerial: Duration
  for test in manager.tests:
    totalDurationSerial += test.duration
    if test.status == IntegrationTestStatus.Ok:
      inc successes
  # estimated time saved as serial execution with a single hardhat instance
  # incurs less overhead
  let relativeTimeSaved = ((totalDurationSerial - manager.duration).nanos * 100) div
                          (totalDurationSerial.nanos)
  let passingStyle = if successes < manager.tests.len:
                       fgRed
                     else:
                       fgGreen

  echo "\n▢=====================================================================▢"
  styledEcho "| ", styleBright, styleUnderscore, "INTEGRATION TEST SUMMARY", resetStyle, "".withBorder(Align.Right, 43, {Border.Right})
  echo "".withBorder()
  styledEcho styleBright, "| TOTAL TIME      : ", resetStyle, ($manager.duration).withBorder(Align.Right, 49, {Border.Right})
  styledEcho styleBright, "| TIME SAVED (EST): ", resetStyle, (&"{relativeTimeSaved}%").withBorder(Align.Right, 49, {Border.Right})
  styledEcho "| ", styleBright, passingStyle, "PASSING         : ", resetStyle, passingStyle, (&"{successes} / {manager.tests.len}").align(49), resetStyle, " |"
  echo "▢=====================================================================▢"

proc start*(manager: TestManager) {.async: (raises: [CancelledError, TestManagerError]).} =
  await manager.runTests()
  manager.printResult()

proc stop*(manager: TestManager) {.async: (raises: [CancelledError]).} =
  for test in manager.tests:
    if not test.process.isNil and not test.process.finished:
      await test.process.cancelAndWait()

  for hardhat in manager.hardhats:
    try:
      await hardhat.stop()
    except CatchableError as e:
      trace "failed to stop hardhat node", error = e.msg