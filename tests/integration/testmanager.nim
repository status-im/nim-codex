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
    startHardhat: bool
    testFile: string
    name: string

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

  TestManagerError* = object of CatchableError

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

func init*(
  _: type IntegrationTestConfig,
  testFile: string,
  startHardhat: bool,
  name = ""): IntegrationTestConfig =

  IntegrationTestConfig(
    testFile: testFile,
    name: if name == "":
            testFile.extractFilename
          else:
            name,
    startHardhat: startHardhat
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
    # no need to re-raise this, as it'll eventually have to be logged only
    error "failed to print to terminal", error = parent.msg

proc duration(manager: TestManager): Duration =
  manager.timeEnd - manager.timeStart

proc duration(test: IntegrationTest): Duration =
  test.timeEnd - test.timeStart

proc startHardhat(
  manager: TestManager,
  config: IntegrationTestConfig): Future[Hardhat] {.async: (raises: [CancelledError, TestManagerError]).} =

  var args: seq[string] = @[]
  var port: int

  let hardhat = Hardhat.new()
  manager.hardhats.add hardhat

  proc onOutputLineCaptured(line: string) {.raises: [].} =
    hardhat.output.add line

  withLock(manager.hardhatPortLock):
    port = await nextFreePort(manager.lastHardhatPort + 10)
    manager.lastHardhatPort = port

  args.add("--port")
  args.add($port)

  trace "starting hardhat process on port ", port
  try:
    let node = await HardhatProcess.startNode(
      args,
      false,
      "hardhat for '" & config.name & "'",
      onOutputLineCaptured)
    await node.waitUntilStarted()
    hardhat.process = node
    hardhat.port = port
    return hardhat
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raiseTestManagerError "hardhat node failed to start: " & e.msg, e

proc printResult(
  test: IntegrationTest,
  colour: ForegroundColor) =

  styledEcho styleBright, colour, &"[{toUpper $test.status}] ",
            resetStyle, test.config.name,
            resetStyle, styleDim, &" ({test.duration})"

proc printOutputMarker(
  test: IntegrationTest,
  position: MarkerPosition,
  msg: string) =

  if position == MarkerPosition.Start:
    echo ""

  styledEcho styleBright, bgWhite, fgBlack,
    &"----- {toUpper $position} {test.config.name} {msg} -----"

  if position == MarkerPosition.Finish:
    echo ""

proc printResult(
  test: IntegrationTest,
  processOutput = false,
  testHarnessErrors = false) =

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

proc printSummary(test: IntegrationTest) =
  test.printResult(processOutput = false, testHarnessErrors = false)

proc printStart(test: IntegrationTest) =
  styledEcho styleBright, fgMagenta, &"[Integration test started] ", resetStyle, test.config.name

proc stopHardhat(
  manager: TestManager,
  test: IntegrationTest,
  hardhat: Hardhat) {.async: (raises: [CancelledError, TestManagerError]).} =

  try:
    await hardhat.process.stop()
  except CatchableError as parent:
    raiseTestManagerError("failed to stop hardhat node", parent)


proc buildCommand(
  manager: TestManager,
  test: IntegrationTest,
  hardhatPort: ?int): Future[string] {.async: (raises:[CancelledError, TestManagerError]).} =

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

  let strHardhatPort =
    if not test.config.startHardhat: ""
    else:
      without port =? hardhatPort:
        raiseTestManagerError "hardhatPort required when 'config.startHardhat' is true"
      "-d:HardhatPort=" & $port

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
              &"{strHardhatPort} " &
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
  config: IntegrationTestConfig) {.async: (raises: [CancelledError]).} =

  logScope:
    config

  trace "Running test"

  var test = IntegrationTest(
    config: config,
    testId: $ uint16.example
  )

  test.timeStart = Moment.now()
  manager.tests.add test

  var hardhat: Hardhat
  var hardhatPort = int.none
  var command: string
  try:
    if config.startHardhat:
      hardhat = await manager.startHardhat(config)
      hardhatPort = hardhat.port.some
    command = await manager.buildCommand(test, hardhatPort)
  except TestManagerError as e:
    error "Failed to start hardhat and build command", error = e.msg
    test.timeEnd = Moment.now()
    test.status = IntegrationTestStatus.Error
    test.output = CommandExResponse.failure(e)
    test.printResult(processOutput = manager.debugCodexNodes,
                      testHarnessErrors = manager.debugTestHarness)
    return

  trace "Starting parallel integration test", command
  test.printStart()
  test.process = execCommandEx(
    command = command,
    timeout = manager.testTimeout
  )

  try:

    let output = await test.process # waits on waitForExit
    test.output = success(output)

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

  if config.startHardhat and not hardhat.isNil:
    try:
      trace "Stopping hardhat", name = config.name
      await manager.stopHardhat(test, hardhat)
    except TestManagerError as e:
      warn "Failed to stop hardhat node, continuing",
        error = e.msg, test = test.config.name

    if manager.debugHardhat:
      test.printOutputMarker(MarkerPosition.Start, "Hardhat stdout")
      for line in hardhat.output:
        echo line
      test.printOutputMarker(MarkerPosition.Finish, "Hardhat stdout")

    manager.hardhats.keepItIf( it != hardhat )

  test.timeEnd = Moment.now()
  info "Test completed", name = config.name, duration = test.timeEnd - test.timeStart

proc runTests(manager: TestManager) {.async: (raises: [CancelledError]).} =
  var testFutures: seq[Future[void].Raising([CancelledError])]

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
      await hardhat.process.stop()
    except CatchableError as e:
      trace "failed to stop hardhat node", error = e.msg