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
  Hardhat = ref object
    process: HardhatProcess
    output: seq[string]
    port: int

  TestManager* = ref object
    configs: seq[IntegrationTestConfig]
    tests: seq[IntegrationTest]
    hardhats: seq[Hardhat]
    lastHardhatPort: int
    lastCodexApiPort: int
    lastCodexDiscPort: int
    # Echoes stderr if there's a test failure (eg test failed, compilation
    # error) or error (eg test manager error)
    debugTestHarness: bool
    # Echoes stdout from Hardhat process
    debugHardhat: bool
    # Echoes stdout from the integration test file process. Codex process logs
    # can also be output if a test uses a multinodesuite, requires
    # CodexConfig.debug to be enabled
    debugCodexNodes: bool
    # Shows test status updates at regular time intervals. Useful for running
    # locally while attended. Set to false for unattended runs, eg CI.
    showContinuousStatusUpdates: bool
    timeStart: ?Moment
    timeEnd: ?Moment
    codexPortLock: AsyncLock
    hardhatPortLock: AsyncLock
    hardhatProcessLock: AsyncLock
    testTimeout: Duration # individual test timeout

  IntegrationTestConfig* = object
    startHardhat: bool
    testFile: string
    name: string

  IntegrationTestStatus = enum ## The status of a test when it is done.
    New,      # Test not yet run
    Running,  # Test currently running
    Ok,       # Test file launched, and exited with 0. Indicates all tests completed and passed.
    Failed,   # Test file launched, but exited with a non-zero exit code. Indicates either the test file did not compile, or one or more of the tests in the file failed
    Timeout,  # Test file launched, but the tests did not complete before the timeout.
    Error     # Test file did not launch correctly. Indicates an error occurred running the tests (usually an error in the harness).

  IntegrationTest = ref object
    manager: TestManager
    config: IntegrationTestConfig
    process: Future[CommandExResponse].Raising([AsyncProcessError, AsyncProcessTimeoutError, CancelledError])
    timeStart: ?Moment
    timeEnd: ?Moment
    output: ?!CommandExResponse
    testId: string    # when used in datadir path, prevents data dir clashes
    status: IntegrationTestStatus
    command: string

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

proc printOutputMarker(test: IntegrationTest, position: MarkerPosition, msg: string) {.gcsafe, raises: [].}

proc raiseTestManagerError(msg: string, parent: ref CatchableError = nil) {.raises: [TestManagerError].} =
  raise newException(TestManagerError, msg, parent)

template echoStyled(args: varargs[untyped]) =
  try:
    styledEcho args
  except CatchableError as parent:
    # no need to re-raise this, as it'll eventually have to be logged only
    error "failed to print to terminal", error = parent.msg

proc new*(
  _: type TestManager,
  configs: seq[IntegrationTestConfig],
  debugTestHarness = false,
  debugHardhat = false,
  debugCodexNodes = false,
  showContinuousStatusUpdates = false,
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


proc duration(manager: TestManager): Duration =
  let now = Moment.now()
  (manager.timeEnd |? now) - (manager.timeStart |? now)

proc duration(test: IntegrationTest): Duration =
  let now = Moment.now()
  (test.timeEnd |? now) - (test.timeStart |? now)

proc startHardhat(
  test: IntegrationTest): Future[Hardhat] {.async: (raises: [CancelledError, TestManagerError]).} =

  var args: seq[string] = @[]
  var port: int

  let hardhat = Hardhat.new()

  proc onOutputLineCaptured(line: string) {.raises: [].} =
    hardhat.output.add line

  withLock(test.manager.hardhatPortLock):
    port = await nextFreePort(test.manager.lastHardhatPort + 10)
    test.manager.lastHardhatPort = port

  args.add("--port")
  args.add($port)

  trace "starting hardhat process on port ", port
  try:
    withLock(test.manager.hardhatProcessLock):
      let node = await HardhatProcess.startNode(
        args,
        false,
        "hardhat for '" & test.config.name & "'",
        onOutputLineCaptured)
      hardhat.process = node
      hardhat.port = port
      await node.waitUntilStarted()
      return hardhat
  except CancelledError as e:
    raise e
  except CatchableError as e:
    if not hardhat.isNil:
      test.printOutputMarker(MarkerPosition.Start, "hardhat stdout")
      for line in hardhat.output:
        echo line
      test.printOutputMarker(MarkerPosition.Finish, "hardhat stdout")
    raiseTestManagerError "hardhat node failed to start: " & e.msg, e

proc printResult(
  test: IntegrationTest,
  colour: ForegroundColor) =

  echoStyled styleBright, colour, &"[{toUpper $test.status}] ",
            resetStyle, test.config.name,
            resetStyle, styleDim, &" ({test.duration})"

proc printOutputMarker(
  test: IntegrationTest,
  position: MarkerPosition,
  msg: string) =

  if position == MarkerPosition.Start:
    echo ""

  echoStyled styleBright, bgWhite, fgBlack,
    &"----- {toUpper $position} {test.config.name} {msg} -----"

  if position == MarkerPosition.Finish:
    echo ""

proc printResult(
  test: IntegrationTest,
  printStdOut = test.manager.debugCodexNodes,
  printStdErr = test.manager.debugTestHarness) =

  case test.status:
  of IntegrationTestStatus.New:
    test.printResult(fgBlue)

  of IntegrationTestStatus.Running:
    test.printResult(fgCyan)

  of IntegrationTestStatus.Error:
    if error =? test.output.errorOption:
      test.printResult(fgRed)
      test.printOutputMarker(MarkerPosition.Start, "test harness errors")
      echo "Error during test execution: ", error.msg
      echo "Stacktrace: ", error.getStackTrace()
      test.printOutputMarker(MarkerPosition.Finish, "test harness errors")

  of IntegrationTestStatus.Failed:
    if output =? test.output:
      if printStdErr: #manager.debugTestHarness
        test.printOutputMarker(MarkerPosition.Start,
                                 "test harness errors (stderr)")
        echo output.stdError
        test.printOutputMarker(MarkerPosition.Finish,
                                 "test harness errors (stderr)")
      if printStdOut:
        test.printOutputMarker(MarkerPosition.Start,
                                 "codex node output (stdout)")
        echo output.stdOutput
        test.printOutputMarker(MarkerPosition.Finish,
                                 "codex node output (stdout)")
    test.printResult(fgRed)

  of IntegrationTestStatus.Timeout:
    if printStdOut and
       output =? test.output:
      test.printOutputMarker(MarkerPosition.Start,
                               "codex node output (stdout)")
      echo output.stdOutput
      test.printOutputMarker(MarkerPosition.Finish,
                               "codex node output (stdout)")
    test.printResult(fgYellow)

  of IntegrationTestStatus.Ok:
    if printStdOut and
       output =? test.output:
      test.printOutputMarker(MarkerPosition.Start,
                               "codex node output (stdout)")
      echo output.stdOutput
      test.printOutputMarker(MarkerPosition.Finish,
                               "codex node output (stdout)")
    test.printResult(fgGreen)

proc printSummary(test: IntegrationTest) =
  test.printResult(printStdOut = false, printStdErr = false)

proc printStart(test: IntegrationTest) =
  echoStyled styleBright, fgMagenta, &"[Integration test started] ", resetStyle, test.config.name

proc buildCommand(
  test: IntegrationTest,
  hardhatPort: ?int): Future[string] {.async: (raises:[CancelledError, TestManagerError]).} =

  var apiPort, discPort: int
  withLock(test.manager.codexPortLock):
    # TODO: needed? nextFreePort should take care of this
    # inc by 20 to allow each test to run 20 codex nodes (clients, SPs,
    # validators) giving a good chance the port will be free
    apiPort = await nextFreePort(test.manager.lastCodexApiPort + 20)
    test.manager.lastCodexApiPort = apiPort
    discPort = await nextFreePort(test.manager.lastCodexDiscPort + 20)
    test.manager.lastCodexDiscPort = discPort

  var logging = ""
  if test.manager.debugTestHarness:
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
  withLock(test.manager.hardhatPortLock):
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
proc setup(
  test: IntegrationTest): Future[?Hardhat] {.async: (raises: [CancelledError, TestManagerError]).} =

  var hardhat = Hardhat.none
  var hardhatPort = int.none

  if test.config.startHardhat:
    let hh = await test.startHardhat()
    hardhat = some hh
    hardhatPort = some hh.port
    test.manager.hardhats.add hh

  test.command = await test.buildCommand(hardhatPort)

  return hardhat

proc teardown(
  test: IntegrationTest,
  hardhat: ?Hardhat) {.async: (raises: [CancelledError]).} =

  if test.config.startHardhat and hardhat =? hardhat:
    try:
      trace "Stopping hardhat", name = test.config.name
      await hardhat.process.stop()
    except CatchableError as e:
      warn "Failed to stop hardhat node, continuing",
        error = e.msg, test = test.config.name

    if test.manager.debugHardhat:
      test.printOutputMarker(MarkerPosition.Start, "Hardhat stdout")
      for line in hardhat.output:
        echo line
      test.printOutputMarker(MarkerPosition.Finish, "Hardhat stdout")

    test.manager.hardhats.keepItIf( it != hardhat )

proc start(test: IntegrationTest) {.async: (raises: []).} =

  logScope:
    config = test.config

  trace "Running test"


  test.timeStart = some Moment.now()
  test.status = IntegrationTestStatus.Running

  var hardhat = none Hardhat

  try:

    try:
      hardhat = await test.setup()
    except TestManagerError as e:
      error "Failed to start hardhat and build command", error = e.msg
      test.timeEnd = some Moment.now()
      test.status = IntegrationTestStatus.Error
      test.output = CommandExResponse.failure(e)
      return

    try:
      trace "Starting parallel integration test", command = test.command
      test.printStart()
      test.process = execCommandEx(
        command = test.command,
        timeout = test.manager.testTimeout
      )

      let output = await test.process # waits on waitForExit
      test.output = success(output)

      if output.status != 0:
        test.status = IntegrationTestStatus.Failed
      else:
        test.status = IntegrationTestStatus.Ok

    except AsyncProcessTimeoutError as e:
      test.timeEnd = some Moment.now()
      error "Test timed out", name = test.config.name, duration = test.duration
      test.output = CommandExResponse.failure(e)
      test.status = IntegrationTestStatus.Timeout

    except AsyncProcessError as e:
      test.timeEnd = some Moment.now()
      error "Test failed to complete", name = test.config.name, duration = test.duration
      test.output = CommandExResponse.failure(e)
      test.status = IntegrationTestStatus.Error

    await test.teardown(hardhat)

  except CancelledError:
    discard # start is asyncSpawned, do not propagate

  test.timeEnd = some Moment.now()
  if test.status == IntegrationTestStatus.Ok:
    info "Test completed", name = test.config.name, duration = test.duration

proc continuallyShowUpdates(manager: TestManager) {.async: (raises: []).} =
  try:

    while true:
      let sleepDuration = if manager.duration < 5.minutes:
                            30.seconds
                          else:
                            1.minutes

      if manager.tests.len > 0:
        echo ""
        echoStyled styleBright, bgWhite, fgBlack,
          &"Integration tests status after {manager.duration}"

      for test in manager.tests:
        test.printResult(false, false)

      if manager.tests.len > 0:
        echo ""

      await sleepAsync(sleepDuration)

  except CancelledError as e:
    discard

proc untilTimeout(fut: Future[void], timeout: Duration): Future[bool] {.async: (raises: [CancelledError]).} =
  # workaround for withTimeout, which did not work correctly
  try:
    let timer = sleepAsync(timeout)
    return (await race(fut, timer)) == fut
  except ValueError:
    discard

proc run(test: IntegrationTest) {.async: (raises: []).} =
  try:
    let futStart = test.start()
    let completedBeforeTimeout = await futStart.untilTimeout(test.manager.testTimeout)
    if not completedBeforeTimeout:
      test.timeEnd = some Moment.now()
      error "Test timed out", name = test.config.name, duration = test.duration
      let e = newException(AsyncProcessTimeoutError,
        "Test did not complete before elapsed timeout")
      test.output = CommandExResponse.failure(e)
      test.status = IntegrationTestStatus.Timeout

      if not futStart.finished:
        await futStart.cancelAndWait()

    test.printResult()


  except CancelledError:
    discard # do not propagate due to asyncSpawn

proc runTests(manager: TestManager) {.async: (raises: [CancelledError]).} =
  var testFutures: seq[Future[void]]

  manager.timeStart = some Moment.now()

  echoStyled styleBright, bgWhite, fgBlack,
             "\n[Integration Test Manager] Starting parallel integration tests"

  for config in manager.configs:

    var test = IntegrationTest(
      manager: manager,
      config: config,
      testId: $ uint16.example
    )
    manager.tests.add test

    let futRun = test.run()
    testFutures.add futRun
    asyncSpawn futRun

  await allFutures testFutures

  manager.timeEnd = some Moment.now()

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
  let showSummary = manager.debugCodexNodes or manager.debugHardhat or manager.debugTestHarness

  if showSummary:
    echo ""
    echoStyled styleBright, styleUnderscore, bgWhite, fgBlack,
      &"INTEGRATION TESTS RESULT"

  for test in manager.tests:
    totalDurationSerial += test.duration
    if test.status == IntegrationTestStatus.Ok:
      inc successes
    # because debug output can really make things hard to read, show a nice
    # summary of test results
    if showSummary:
      test.printResult(false, false)

  # estimated time saved as serial execution with a single hardhat instance
  # incurs less overhead
  let relativeTimeSaved = ((totalDurationSerial - manager.duration).nanos * 100) div
                          (totalDurationSerial.nanos)
  let passingStyle = if successes < manager.tests.len:
                       fgRed
                     else:
                       fgGreen


  echo "\n▢=====================================================================▢"
  echoStyled "| ", styleBright, styleUnderscore, "INTEGRATION TEST SUMMARY", resetStyle, "".withBorder(Align.Right, 43, {Border.Right})
  echo "".withBorder()
  echoStyled styleBright, "| TOTAL TIME      : ", resetStyle, ($manager.duration).withBorder(Align.Right, 49, {Border.Right})
  echoStyled styleBright, "| TIME SAVED (EST): ", resetStyle, (&"{relativeTimeSaved}%").withBorder(Align.Right, 49, {Border.Right})
  echoStyled "| ", styleBright, passingStyle, "PASSING         : ", resetStyle, passingStyle, (&"{successes} / {manager.tests.len}").align(49), resetStyle, " |"
  echo "▢=====================================================================▢"

proc start*(manager: TestManager) {.async: (raises: [CancelledError, TestManagerError]).} =
  let futContinuousUpdates = manager.continuallyShowUpdates()
  asyncSpawn futContinuousUpdates

  await manager.runTests()
  await futContinuousUpdates.cancelAndWait()

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