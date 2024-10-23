import os
import std/monotimes
import pkg/datastore
import pkg/chronos
import pkg/questionable/results

type
  TempLevelDb* = ref object
    currentPath: string
    ds: LevelDbDatastore

var number = 0

proc newDb*(self: TempLevelDb): Datastore =
  if self.currentPath.len > 0:
    raiseAssert("TempLevelDb already active.")
  self.currentPath = getTempDir() / "templeveldb" / $number / $getmonotime()
  inc number
  createdir(self.currentPath)
  self.ds = LevelDbDatastore.new(self.currentPath).tryGet()
  return self.ds

proc destroyDb*(self: TempLevelDb): Future[void] {.async.} =
  if self.currentPath.len == 0:
    raiseAssert("TempLevelDb not active.")
  try:
    (await self.ds.close()).tryGet()
  finally:
    removedir(self.currentPath)
    self.currentPath = ""
