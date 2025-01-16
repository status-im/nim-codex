import pkg/asynctest/chronos/unittest
import times, strutils

type
  TimedOutputFormatter* = ref object of ConsoleOutputFormatter
    testStartTime: float

method testStarted*(formatter: TimedOutputFormatter, testName: string) {.gcsafe.} =
  formatter.testStartTime = epochTime()

method testEnded*(formatter: TimedOutputFormatter, testResult: TestResult) =
  let time = epochTime() - formatter.testStartTime
  let timeStr = time.formatFloat(ffDecimal, precision = 8)
  # There doesn't seem to be an easy way to override the echo in the base class
  # without changing std/unittest, or copying most of the code here.
  # We use a second line as a workaround.
  procCall formatter.ConsoleOutputFormatter.testEnded(testResult)
  echo "      time = ", timeStr, " sec"

addOutputFormatter(TimedOutputFormatter())

export unittest
