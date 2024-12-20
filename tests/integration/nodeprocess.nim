import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos/asyncproc
import pkg/libp2p
import std/os
import std/strutils
import codex/conf
import codex/utils/exceptions
import codex/utils/trackedfutures
import ./codexclient

export codexclient
export chronicles

logScope:
  topics = "integration testing node process"

type
  NodeProcess* = ref object of RootObj
    process*: AsyncProcessRef
    arguments*: seq[string]
    debug: bool
    trackedFutures*: TrackedFutures
    name*: string
  NodeProcessError* = object of CatchableError

method workingDir(node: NodeProcess): string {.base.} =
  raiseAssert "not implemented"

method executable(node: NodeProcess): string {.base.} =
  raiseAssert "not implemented"

method startedOutput(node: NodeProcess): string {.base.} =
  raiseAssert "not implemented"

method processOptions(node: NodeProcess): set[AsyncProcessOption] {.base.} =
  raiseAssert "not implemented"

method outputLineEndings(node: NodeProcess): string {.base, raises: [].} =
  raiseAssert "not implemented"

method onOutputLineCaptured(node: NodeProcess, line: string) {.base, raises: [].} =
  raiseAssert "not implemented"

method start*(node: NodeProcess) {.base, async.} =
  logScope:
    nodeName = node.name

  let poptions = node.processOptions + {AsyncProcessOption.StdErrToStdOut}
  trace "starting node",
    args = node.arguments,
    executable = node.executable,
    workingDir = node.workingDir,
    processOptions = poptions

  try:
    if node.debug:
      echo "starting codex node with args: ", node.arguments.join(" ")
    node.process = await startProcess(
      node.executable,
      node.workingDir,
      node.arguments,
      options = poptions,
      stdoutHandle = AsyncProcess.Pipe
    )
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "failed to start node process", error = e.msg

proc captureOutput(
  node: NodeProcess,
  output: string,
  started: Future[void]
) {.async: (raises: []).} =

  logScope:
    nodeName = node.name

  trace "waiting for output", output

  let stream = node.process.stdoutStream

  try:
    while node.process.running.option == some true:
      while(let line = await stream.readLine(0, node.outputLineEndings); line != ""):
        if node.debug:
          # would be nice if chronicles could parse and display with colors
          echo line

        if not started.isNil and not started.finished and line.contains(output):
          started.complete()

        node.onOutputLineCaptured(line)

        await sleepAsync(1.millis)
      await sleepAsync(1.millis)

  except CancelledError:
    discard # do not propagate as captureOutput was asyncSpawned

  except AsyncStreamError as e:
    error "error reading output stream", error = e.msgDetail

proc startNode*[T: NodeProcess](
  _: type T,
  args: seq[string],
  debug: string | bool = false,
  name: string
): Future[T] {.async.} =

  ## Starts a Codex Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let node = T(
    arguments: @args,
    debug: ($debug != "false"),
    trackedFutures: TrackedFutures.new(),
    name: name
  )
  await node.start()
  return node

method stop*(node: NodeProcess) {.base, async.} =
  logScope:
    nodeName = node.name

  await node.trackedFutures.cancelTracked()
  if node.process != nil:
    try:
      trace "terminating node process..."
      if errCode =? node.process.terminate().errorOption:
        error "failed to terminate process", errCode = $errCode

      trace "waiting for node process to exit"
      let exitCode = await node.process.waitForExit(3.seconds)
      if exitCode > 0:
        error "failed to exit process, check for zombies", exitCode

      trace "closing node process' streams"
      await node.process.closeWait()
    except CancelledError as error:
      raise error
    except CatchableError as e:
      error "error stopping node process", error = e.msg

    finally:
      node.process = nil

    trace "node stopped"

proc waitUntilOutput*(node: NodeProcess, output: string) {.async.} =
  logScope:
    nodeName = node.name

  trace "waiting until", output

  let started = newFuture[void]()
  let fut = node.captureOutput(output, started)
  node.trackedFutures.track(fut)
  asyncSpawn fut
  await started.wait(60.seconds) # allow enough time for proof generation

proc waitUntilStarted*(node: NodeProcess) {.async.} =
  logScope:
    nodeName = node.name

  try:
    await node.waitUntilOutput(node.startedOutput)
    trace "node started"
  except AsyncTimeoutError:
    # attempt graceful shutdown in case node was partially started, prevent
    # zombies
    await node.stop()
    # raise error here so that all nodes (not just this one) can be
    # shutdown gracefully
    raise newException(NodeProcessError, "node did not output '" &
      node.startedOutput & "'")

proc restart*(node: NodeProcess) {.async.} =
  await node.stop()
  await node.start()
  await node.waitUntilStarted()

method removeDataDir*(node: NodeProcess) {.base.} =
  raiseAssert "[removeDataDir] not implemented"
