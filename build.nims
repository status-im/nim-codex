mode = ScriptMode.Verbose


### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  when compiles(commandLineParams()):
    for param in commandLineParams():
      extra_params &= " " & param
  else:
    for i in 2..<paramCount():
      extra_params &= " " & paramStr(i)

  let cmd = "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"
  exec(cmd)

proc test(name: string, srcDir = "tests/", params = "", lang = "c") =
  buildBinary name, srcDir, params
  exec "build/" & name

task codex, "build codex binary":
  buildBinary "codex", params = "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE"

task testCodex, "Build & run Codex tests":
  test "testCodex", params = "-d:codex_enable_proof_failures=true"

task testContracts, "Build & run Codex Contract tests":
  test "testContracts"

task testIntegration, "Run integration tests":
  buildBinary "codex", params = "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE -d:codex_enable_proof_failures=true"
  test "testIntegration"

task build, "build codex binary":
  codexTask()

task test, "Run tests":
  testCodexTask()

task testAll, "Run all tests (except for Taiko L2 tests)":
  testCodexTask()
  testContractsTask()
  testIntegrationTask()

task testTaiko, "Run Taiko L2 tests":
  codexTask()
  test "testTaiko"

import strutils
import os

task coverage, "generates code coverage report":
  var (output, exitCode) = gorgeEx("which lcov")
  if exitCode != 0:
    echo "  ************************** ⛔️ ERROR ⛔️ **************************"
    echo "  **   ERROR: lcov not found, it must be installed to run code   **"
    echo "  **   coverage locally                                          **"
    echo "  *****************************************************************"
    quit 1

  (output, exitCode) = gorgeEx("gcov --version")
  if output.contains("Apple LLVM"):
    echo "  ************************* ⚠️ WARNING ⚠️  *************************"
    echo "  **   WARNING: Using Apple's llvm-cov in place of gcov, which   **"
    echo "  **   emulates an old version of gcov (4.2.0) and therefore     **"
    echo "  **   coverage results will differ than those on CI (which      **"
    echo "  **   uses a much newer version of gcov).                       **"
    echo "  *****************************************************************"

  var nimSrcs = " "
  for f in walkDirRec("codex", {pcFile}):
    if f.endswith(".nim"): nimSrcs.add " " & f.absolutePath.quoteShell()

  echo "======== Running Tests ======== "
  test "coverage", srcDir = "tests/", params = " --nimcache:nimcache/coverage -d:release -d:codex_enable_proof_failures=true"
  exec("rm nimcache/coverage/*.c")
  rmDir("coverage"); mkDir("coverage")
  echo " ======== Running LCOV ======== "
  exec("lcov --capture --directory nimcache/coverage --output-file coverage/coverage.info")
  exec("lcov --extract coverage/coverage.info --output-file coverage/coverage.f.info " & nimSrcs)
  echo " ======== Generating HTML coverage report ======== "
  exec("genhtml coverage/coverage.f.info --output-directory coverage/report ")
  echo " ======== Coverage report Done ======== "

task showCoverage, "open coverage html":
  echo " ======== Opening HTML coverage report in browser... ======== "
  if findExe("open") != "":
    exec("open coverage/report/index.html")
