## Seeds test LMDB and SQLite databases for integration tests.
## Run with CWD set to the desired data directory.

import std/os
import ../types, ../database, ../keyvalue, ../secret

# Create SQLite database (multi-db structure: directory with numbered files)
let sqlDir = "smplcmts.sqlite"
createDir(sqlDir)
let db = openDatabase(sqlDir / "0")
initDb(db)

# Seed users
db.exec("INSERT INTO user (id, username, email_hash) VALUES (?, ?, ?)",
  1, "testuser", saltedHash("test@test.com"))

# Create KV store
let (kv, expiry) = initKeyValue("smplcmts.lmdb")

# Site mapping
kv.site["localhost"] = 0

# Session for user with username
kv.session[saltedHash("testsession")] = User(
  id: 1, username: "testuser", emailHash: saltedHash("test@test.com"))

# Session for user without username (not yet in SQLite)
kv.session[saltedHash("nosession")] = User(
  id: 0, username: "", emailHash: saltedHash("test2@test.com"))

# Login entries for auth token tests
kv.login[saltedHash("testauthtoken")] = Login(
  emailHash: saltedHash("logintest@test.com"),
  url: "http://localhost:5111/",
  notify: "", siteId: 0)

kv.login[saltedHash("testauthtoken2")] = Login(
  emailHash: saltedHash("logintest2@test.com"),
  url: "http://localhost:5111/",
  notify: "", siteId: 0)

# Notification subscription for unsubscribe test
kv.notify[1] = "test@test.com"

echo "Seed complete"
quit(0)
