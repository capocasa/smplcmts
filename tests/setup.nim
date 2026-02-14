## Test setup - this module must be imported BEFORE serve
## It creates test directories and seeds test data

import std/os
import ../types, ../database, ../keyvalue, ../secret

const
  testDir* = "/tmp/smplcmts_test"
  testSqlDir* = testDir / "smplcmts.sqlite"
  testKvPath* = testDir / "smplcmts.lmdb"
  testPort* = 5111

# Clean and create test directory
removeDir(testDir)
createDir(testDir)
createDir(testSqlDir)

# Copy static files
const projectDir = currentSourcePath().parentDir().parentDir()
copyFile(projectDir / "smplcmts.css", testDir / "smplcmts.css")
copyFile(projectDir / "smplcmts.js", testDir / "smplcmts.js")

# Initialize SQLite
let testDb* = openDatabase(testSqlDir / "0")
initDb(testDb)
testDb.exec("INSERT INTO user (id, username, email_hash) VALUES (?, ?, ?)",
  1, "testuser", saltedHash("test@test.com"))

# Initialize LMDB (discard expiry - we only need kv for seeding)
let (testKv*, _) = initKeyValue(testKvPath)
testKv.site["localhost"] = 0
testKv.session[saltedHash("testsession")] = User(
  id: 1, username: "testuser", emailHash: saltedHash("test@test.com"))
testKv.session[saltedHash("nosession")] = User(
  id: 0, username: "", emailHash: saltedHash("test2@test.com"))
testKv.login[saltedHash("testauthtoken")] = Login(
  emailHash: saltedHash("logintest@test.com"),
  url: "http://localhost:" & $testPort & "/",
  notify: "", siteId: 0)
testKv.login[saltedHash("testauthtoken2")] = Login(
  emailHash: saltedHash("logintest2@test.com"),
  url: "http://localhost:" & $testPort & "/",
  notify: "", siteId: 0)
testKv.notify[1] = "test@test.com"

echo "Test data initialized at ", testDir
