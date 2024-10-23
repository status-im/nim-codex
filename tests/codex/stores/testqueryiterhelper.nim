import std/sugar

import pkg/stew/results
import pkg/questionable
import pkg/chronos
import pkg/datastore/typedds
import pkg/datastore/sql/sqliteds
import pkg/codex/stores/queryiterhelper
import pkg/codex/utils/asynciter

import ../../asynctest
import ../helpers

proc encode(s: string): seq[byte] =
  s.toBytes()

proc decode(T: type string, bytes: seq[byte]): ?!T =
  success(string.fromBytes(bytes))

asyncchecksuite "Test QueryIter helper":
  var
    tds: TypedDatastore

  setupAll:
    tds = TypedDatastore.init(SQLiteDatastore.new(Memory).tryGet())

  teardownAll:
    (await tds.close()).tryGet

  test "Should auto-dispose when QueryIter finishes":
    let
      source = {
        "a": "11",
        "b": "22"
      }.toTable
      Root = Key.init("/queryitertest").tryGet()

    for k, v in source:
      let key = (Root / k).tryGet()
      (await tds.put(key, v)).tryGet()

    var
      disposed = false
      queryIter = (await query[string](tds, Query.init(Root))).tryGet()

    let iterDispose: IterDispose = queryIter.dispose
    queryIter.dispose = () => (disposed = true; iterDispose())

    let
      iter1 = (await toAsyncIter[string](queryIter)).tryGet()
      iter2 = await filterSuccess[string](iter1)

    var items = initTable[string, string]()

    for fut in iter2:
      let item = await fut

      items[item.key.value] = item.value

    check:
      items == source
      disposed == true
      queryIter.finished == true
      iter1.finished == true
      iter2.finished == true
