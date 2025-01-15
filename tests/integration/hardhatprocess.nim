import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos
import pkg/chronos/asyncproc
import pkg/stew/io2
import std/os
import std/sets
import std/sequtils
import std/strutils
import pkg/codex/conf
import pkg/codex/utils/trackedfutures
import ./codexclient
import ./nodeprocess

export codexclient
export chronicles

logScope:
  topics = "integration testing hardhat process"
  nodeName = "hardhat"

type HardhatProcess* = ref object of NodeProcess
  logFile: ?IoHandle

method workingDir(node: HardhatProcess): string =
  return currentSourcePath() / ".." / ".." / ".." / "vendor" / "codex-contracts-eth"

method executable(node: HardhatProcess): string =
  return "node_modules" / ".bin" / "hardhat"

method startedOutput(node: HardhatProcess): string =
  return "Started HTTP and WebSocket JSON-RPC server at"

method processOptions(node: HardhatProcess): set[AsyncProcessOption] =
  return {}

method outputLineEndings(node: HardhatProcess): string {.raises: [].} =
  return "\n"

proc openLogFile(node: HardhatProcess, logFilePath: string): IoHandle =
  let logFileHandle =
    openFile(logFilePath, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate})

  without fileHandle =? logFileHandle:
    fatal "failed to open log file",
      path = logFilePath, errorCode = $logFileHandle.error

    raiseAssert "failed to open log file, aborting"

  return fileHandle

method start*(node: HardhatProcess) {.async.} =
  let poptions = node.processOptions + {AsyncProcessOption.StdErrToStdOut}
  trace "starting node",
    args = node.arguments,
    executable = node.executable,
    workingDir = node.workingDir,
    processOptions = poptions

  try:
    node.process = await startProcess(
      node.executable,
      node.workingDir,
      @["node", "--export", "deployment-localhost.json"].concat(node.arguments),
      options = poptions,
      stdoutHandle = AsyncProcess.Pipe,
    )
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "failed to start hardhat process", error = e.msg

proc startNode*(
    _: type HardhatProcess,
    args: seq[string],
    debug: string | bool = false,
    name: string,
): Future[HardhatProcess] {.async.} =
  var logFilePath = ""

  var arguments = newSeq[string]()
  for arg in args:
    if arg.contains "--log-file=":
      logFilePath = arg.split("=")[1]
    else:
      arguments.add arg

  trace "starting hardhat node", arguments
  ## Starts a Hardhat Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let hardhat = HardhatProcess(
    arguments: arguments,
    debug: ($debug != "false"),
    trackedFutures: TrackedFutures.new(),
    name: "hardhat",
  )

  await hardhat.start()

  if logFilePath != "":
    hardhat.logFile = some hardhat.openLogFile(logFilePath)

  return hardhat

method onOutputLineCaptured(node: HardhatProcess, line: string) =
  without logFile =? node.logFile:
    return

  if error =? logFile.writeFile(line & "\n").errorOption:
    error "failed to write to hardhat file", errorCode = $error
    discard logFile.closeFile()
    node.logFile = none IoHandle

method stop*(node: HardhatProcess) {.async.} =
  # terminate the process
  await procCall NodeProcess(node).stop()

  if logFile =? node.logFile:
    trace "closing hardhat log file"
    discard logFile.closeFile()

method removeDataDir*(node: HardhatProcess) =
  discard
