import ./codex/teststores
import ./codex/testblockexchange
import ./codex/testasyncheapqueue
import ./codex/testchunking
import ./codex/testlogutils
import ./codex/testmanifest
import ./codex/testnode
import ./codex/teststorestream
import ./codex/testpurchasing
import ./codex/testsales
import ./codex/testerasure
import ./codex/testutils
import ./codex/testclock
import ./codex/testsystemclock
import ./codex/testvalidation
import ./codex/testasyncstreamwrapper
import ./codex/testmerkletree
import ./codex/testslots
import ./codex/testindexingstrategy

{.warning[UnusedImport]: off.}

when isMainModule and defined(chronosClosureDurationMetric):
  import std/tables
  import chronos

  let metrics = getCallbackDurations()
  echo "\ncsv timings print: "
  echo "file, ", "line, ", "procedure, ", "count, ", "avg micros, ", "min, ", "max, ", "total "

  for (k,v) in metrics.pairs():
    if v.count > 0:
      let avgMicros = microseconds(v.totalDuration div v.count)
      let minMicros = microseconds(v.minSingleTime)
      let maxMicros = microseconds(v.maxSingleTime)
      let totalMicros = microseconds(v.totalDuration)
      echo  k.file, ", ", k.line, ", ", k.procedure, ", ", v.count, ", ",
              avgMicros, ", ", minMicros, ", ", maxMicros, ", ", totalMicros

  echo "\nflat print: "
  for (k,v) in metrics.pairs():
    if v.count > 0:
      echo ""
      echo "metric: ", $k
      echo "count: ", v.count
      echo "min: ", v.minSingleTime
      echo "avg: ", v.totalDuration div v.count
      echo "max: ", v.maxSingleTime
      echo "total: ", v.totalDuration