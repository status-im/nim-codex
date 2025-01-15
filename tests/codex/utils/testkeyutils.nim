import std/unittest
import std/os
import codex/utils/keyutils
import ../helpers

when defined(windows):
  import stew/windows/acl

checksuite "keyutils":
  let path = getTempDir() / "CodexTest"

  setup:
    os.createDir(path)

  teardown:
    os.removeDir(path)

  test "creates a key file when it does not exist yet":
    check setupKey(path / "keyfile").isOk
    check fileExists(path / "keyfile")

  test "stores key in a file that's only readable by the user":
    discard setupKey(path / "keyfile").get()
    when defined(posix):
      check getFilePermissions(path / "keyfile") == {fpUserRead, fpUserWrite}
    when defined(windows):
      check checkCurrentUserOnlyACL(path / "keyfile").get()

  test "reads key file when it does exist":
    let key = setupKey(path / "keyfile").get()
    check setupKey(path / "keyfile").get() == key
