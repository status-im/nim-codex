import std/os
import std/strformat
import std/strutils
import std/terminal
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

  IntegrationTestStatus* = enum ## The status of a test when it is done.
    OK,
    FAILED,
    TIMEOUT,
    ERROR

  IntegrationTest = ref object
    config: IntegrationTestConfig
    process: Future[CommandExResponse].Raising([AsyncProcessError, AsyncProcessTimeoutError, CancelledError])
    timeStart: Moment
    timeEnd: Moment
    output: ?!CommandExResponse
    testId: string    # when used in datadir path, prevents data dir clashes
    status: IntegrationTestStatus

  TestManagerError = object of CatchableError
  FormattingError = object of TestManagerError
  LockError = object of TestManagerError

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

  styledEcho styleBright, colour, &"[{test.status}] ",
            resetStyle, test.config.name,
            resetStyle, styleDim, &" ({test.duration})"

proc printResult(
  test: IntegrationTest,
  processOutput = false,
  testHarnessErrors = false) {.raises: [TestManagerError].} =

  if test.status == IntegrationTestStatus.ERROR and
    error =? test.output.errorOption:
    test.printResult(fgRed)
    if testHarnessErrors:
      echo "Error during test execution: ", error.msg
      echo "Stacktrace: ", error.getStackTrace()

  elif test.status == IntegrationTestStatus.FAILED:
    if output =? test.output:
      if testHarnessErrors: #manager.debugTestHarness
        echo output.stdError
      if processOutput:
        echo output.stdOutput
    test.printResult(fgRed)

  elif test.status == IntegrationTestStatus.TIMEOUT:
    test.printResult(fgYellow)

  elif test.status == IntegrationTestStatus.OK:
    if processOutput and
      output =? test.output:
      echo output.stdOutput
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
      test.status = IntegrationTestStatus.ERROR
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
      test.status = IntegrationTestStatus.FAILED
    else:
      test.status = IntegrationTestStatus.OK

    test.printResult(processOutput = manager.debugCodexNodes,
                     testHarnessErrors = manager.debugTestHarness)

  except CancelledError as e:
    raise e

  except AsyncProcessTimeoutError as e:
    test.timeEnd = Moment.now()
    error "Test timed out", name = config.name, duration = test.timeEnd - test.timeStart
    test.output = CommandExResponse.failure(e)
    test.status = IntegrationTestStatus.TIMEOUT
    test.printResult(processOutput = manager.debugCodexNodes,
                     testHarnessErrors = manager.debugTestHarness)

  except AsyncProcessError as e:
    test.timeEnd = Moment.now()
    error "Test failed to complete", name = config.name,duration = test.timeEnd - test.timeStart
    test.output = CommandExResponse.failure(e)
    test.status = IntegrationTestStatus.ERROR
    test.printResult(processOutput = manager.debugCodexNodes,
                     testHarnessErrors = manager.debugTestHarness)

proc runTests(manager: TestManager) {.async: (raises: [CancelledError, TestManagerError]).} =
  var testFutures: seq[Future[void].Raising([CancelledError, TestManagerError])]

  manager.timeStart = Moment.now()

  styledEcho styleBright, bgWhite, fgBlack,
             "[Integration Test Manager] Starting parallel integration tests"

  for config in manager.configs:
    testFutures.add manager.runTest(config)

  await allFutures testFutures

  manager.timeEnd = Moment.now()

type
  Border {.pure.} = enum
    Left, Right
  Align {.pure.} = enum
    Left, Right

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
    if test.status == IntegrationTestStatus.OK:
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