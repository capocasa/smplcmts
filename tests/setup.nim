## Test setup - this module must be imported BEFORE serve
## It creates test directories and seeds test data

import std/os
import ../database, ../keyvalue

const
  testDir* = "/tmp/smplcmts_test"
  testSqlDir* = testDir / "smplcmts.sqlite"
  testKvPath* = testDir / "smplcmts.lmdb"
  testPort* = 5111

proc initTestData*() =
  ## Initialize test directories and seed data. Must be called before serve import.
  # Clean and create test directory
  removeDir(testDir)
  createDir(testDir)
  createDir(testSqlDir)

  # Copy static files
  const projectDir = currentSourcePath().parentDir().parentDir()
  copyFile(projectDir / "smplcmts.css", testDir / "smplcmts.css")
  copyFile(projectDir / "smplcmts.js", testDir / "smplcmts.js")

  # Initialize SQLite - schema only, users created via login flow
  let testDb = openDatabase(testSqlDir / "0")
  initDb(testDb)

  # Initialize LMDB - only site mapping needed, auth is done via real login flow
  let (testKv, _) = initKeyValue(testKvPath)
  testKv.site["localhost"] = 0

  # Close handles so serve.nim can open its own
  testDb.close()
  testKv.main.close()

  echo "Test data initialized at ", testDir
