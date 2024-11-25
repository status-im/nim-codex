import std/sugar
import pkg/questionable
import pkg/chronos
import pkg/upraises
import ../logutils
import ./then
import ./trackedfutures

push: {.upraises:[].}

type
  Machine* = ref object of RootObj
    state: State
    running: Future[void]
    scheduled: AsyncQueue[Event]
    started: bool
    trackedFutures: TrackedFutures
  State* = ref object of RootObj
  Query*[T] = proc(state: State): T
  Event* = proc(state: State): ?State {.gcsafe, upraises:[].}

logScope:
  topics = "statemachine"

proc new*[T: Machine](_: type T): T =
  T(trackedFutures: TrackedFutures.new())

method `$`*(state: State): string {.base.} =
  raiseAssert "not implemented"

proc transition(_: type Event, previous, next: State): Event =
  return proc (state: State): ?State =
    if state == previous:
      return some next

proc query*[T](machine: Machine, query: Query[T]): ?T =
  if machine.state.isNil:
    none T
  else:
    some query(machine.state)

proc schedule*(machine: Machine, event: Event) =
  if not machine.started:
    return

  try:
    machine.scheduled.putNoWait(event)
  except AsyncQueueFullError:
    raiseAssert "unlimited queue is full?!"

method run*(state: State, machine: Machine): Future[?State] {.base, async.} =
  discard

method onError*(state: State, error: ref CatchableError): ?State {.base.} =
  raise (ref Defect)(msg: "error in state machine: " & error.msg, parent: error)

proc onError(machine: Machine, error: ref CatchableError): Event =
  return proc (state: State): ?State =
    state.onError(error)

proc run(machine: Machine, state: State) {.async.} =
  if next =? await state.run(machine):
    machine.schedule(Event.transition(state, next))

proc scheduler(machine: Machine) {.async.} =
  var running: Future[void]
  while machine.started:
    let event = await machine.scheduled.get().track(machine)
    if next =? event(machine.state):
      if not running.isNil and not running.finished:
        trace "cancelling current state", state = $machine.state
        await running.cancelAndWait()
      let fromState = if machine.state.isNil: "<none>" else: $machine.state
      machine.state = next
      debug "enter state", state = fromState & " => " & $machine.state
      running = machine.run(machine.state)
      running
        .track(machine)
        .cancelled(proc() = trace "state.run cancelled, swallowing", state = $machine.state)
        .catch(proc(err: ref CatchableError) =
          trace "error caught in state.run, calling state.onError", state = $machine.state
          machine.schedule(machine.onError(err))
        )

proc start*(machine: Machine, initialState: State) =
  if machine.started:
    return

  if machine.scheduled.isNil:
    machine.scheduled = newAsyncQueue[Event]()

  machine.started = true
  try:
    discard machine.scheduler().track(machine)
    machine.schedule(Event.transition(machine.state, initialState))
  except CancelledError as e:
    discard
  except CatchableError as e:
    error("Error in scheduler", error = e.msg)

proc stop*(machine: Machine) {.async.} =
  if not machine.started:
    return

  trace "stopping state machine"

  machine.started = false
  await machine.trackedFutures.cancelTracked()

  machine.state = nil
