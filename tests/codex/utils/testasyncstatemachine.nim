import pkg/questionable
import pkg/chronos
import pkg/upraises
import codex/utils/asyncstatemachine

import ../../asynctest
import ../helpers

type
  State1 = ref object of State
  State2 = ref object of State
  State3 = ref object of State
  State4 = ref object of State

var runs, cancellations, errors = [0, 0, 0, 0]

method `$`(state: State1): string =
  "State1"

method `$`(state: State2): string =
  "State2"

method `$`(state: State3): string =
  "State3"

method `$`(state: State4): string =
  "State4"

method run(state: State1, machine: Machine): Future[?State] {.async.} =
  inc runs[0]
  return some State(State2.new())

method run(state: State2, machine: Machine): Future[?State] {.async.} =
  inc runs[1]
  try:
    await sleepAsync(1.hours)
  except CancelledError:
    inc cancellations[1]
    raise

method run(state: State3, machine: Machine): Future[?State] {.async.} =
  inc runs[2]

method run(state: State4, machine: Machine): Future[?State] {.async.} =
  inc runs[3]
  raise newException(ValueError, "failed")

method onMoveToNextStateEvent*(state: State): ?State {.base, upraises: [].} =
  discard

method onMoveToNextStateEvent(state: State2): ?State =
  some State(State3.new())

method onMoveToNextStateEvent(state: State3): ?State =
  some State(State1.new())

method onError(state: State1, error: ref CatchableError): ?State =
  inc errors[0]

method onError(state: State2, error: ref CatchableError): ?State =
  inc errors[1]

method onError(state: State3, error: ref CatchableError): ?State =
  inc errors[2]

method onError(state: State4, error: ref CatchableError): ?State =
  inc errors[3]
  some State(State2.new())

asyncchecksuite "async state machines":
  var machine: Machine

  proc moveToNextStateEvent(state: State): ?State =
    state.onMoveToNextStateEvent()

  setup:
    runs = [0, 0, 0, 0]
    cancellations = [0, 0, 0, 0]
    errors = [0, 0, 0, 0]
    machine = Machine.new()

  test "should call run on start state":
    machine.start(State1.new())
    check eventually runs[0] == 1

  test "moves to next state when run completes":
    machine.start(State1.new())
    check eventually runs == [1, 1, 0, 0]

  test "state2 moves to state3 on event":
    machine.start(State2.new())
    machine.schedule(moveToNextStateEvent)
    check eventually runs == [0, 1, 1, 0]

  test "state transition will cancel the running state":
    machine.start(State2.new())
    machine.schedule(moveToNextStateEvent)
    check eventually cancellations == [0, 1, 0, 0]

  test "scheduled events are handled one after the other":
    machine.start(State2.new())
    machine.schedule(moveToNextStateEvent)
    machine.schedule(moveToNextStateEvent)
    check eventually runs == [1, 2, 1, 0]

  test "stops scheduling and current state":
    machine.start(State2.new())
    await sleepAsync(1.millis)
    await machine.stop()
    machine.schedule(moveToNextStateEvent)
    await sleepAsync(1.millis)
    check runs == [0, 1, 0, 0]
    check cancellations == [0, 1, 0, 0]

  test "forwards errors to error handler":
    machine.start(State4.new())
    check eventually errors == [0, 0, 0, 1] and runs == [0, 1, 0, 1]

  test "error handler ignores CancelledError":
    machine.start(State2.new())
    machine.schedule(moveToNextStateEvent)
    check eventually cancellations == [0, 1, 0, 0]
    check errors == [0, 0, 0, 0]

  test "queries properties of the current state":
    proc description(state: State): string =
      $state

    machine.start(State2.new())
    check eventually machine.query(description) == some "State2"
    machine.schedule(moveToNextStateEvent)
    check eventually machine.query(description) == some "State3"

  test "stops handling queries when stopped":
    proc description(state: State): string =
      $state

    machine.start(State2.new())
    check eventually machine.query(description).isSome
    await machine.stop()
    check machine.query(description).isNone
