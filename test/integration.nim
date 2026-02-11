## Integration tests for smplcmts.
## Prerequisites: nim c test/seed.nim && nim c -d:release --mm:refc smplcmts.nim
## Run: nim c -r test/integration.nim

import std/[httpclient, os, osproc, strutils, unittest, uri, httpcore, times, streams]
import ../secret

const
  port = 5111
  baseUrl = "http://localhost:" & $port
  projectDir = currentSourcePath().parentDir().parentDir()

# --- HTTP helpers ---

proc get(path: string, cookie = ""): Response =
  let c = newHttpClient()
  defer: c.close()
  if cookie != "":
    c.headers = newHttpHeaders({"Cookie": "CommentSessionToken=" & cookie})
  c.get(baseUrl & path)

proc getNoRedirect(path: string): Response =
  let c = newHttpClient(maxRedirects = 0)
  defer: c.close()
  c.get(baseUrl & path)

proc post(path: string, body = "", cookie = ""): Response =
  let c = newHttpClient()
  defer: c.close()
  var hdrs = @[("Content-Type", "application/x-www-form-urlencoded")]
  if cookie != "": hdrs.add ("Cookie", "CommentSessionToken=" & cookie)
  c.headers = newHttpHeaders(hdrs)
  c.post(baseUrl & path, body = body)

proc put(path: string, body = "", cookie = ""): Response =
  let c = newHttpClient()
  defer: c.close()
  var hdrs = @[("Content-Type", "application/x-www-form-urlencoded")]
  if cookie != "": hdrs.add ("Cookie", "CommentSessionToken=" & cookie)
  c.headers = newHttpHeaders(hdrs)
  c.request(baseUrl & path, httpMethod = HttpPut, body = body)

proc delete(path: string, cookie = ""): Response =
  let c = newHttpClient()
  defer: c.close()
  if cookie != "":
    c.headers = newHttpHeaders({"Cookie": "CommentSessionToken=" & cookie})
  c.request(baseUrl & path, httpMethod = HttpDelete)

proc options(path: string): Response =
  let c = newHttpClient()
  defer: c.close()
  c.headers = newHttpHeaders({"Origin": "http://localhost"})
  c.request(baseUrl & path, httpMethod = HttpOptions)

proc formBody(pairs: openArray[(string, string)]): string =
  encodeQuery(pairs, omitEq = false)

proc findCommentId(html: string): int =
  let marker = "id=\"comment-"
  let pos = html.find(marker)
  assert pos >= 0, "No comment found in HTML"
  let start = pos + marker.len
  let endP = html.find('"', start)
  result = parseInt(html[start..<endP])

# --- Setup ---

let tmpDir = getTempDir() / "smplcmts_test_" & $getTime().toUnix
createDir(tmpDir)
echo "Test dir: ", tmpDir

# Copy static files
copyFile(projectDir / "smplcmts.css", tmpDir / "smplcmts.css")
copyFile(projectDir / "smplcmts.js", tmpDir / "smplcmts.js")

# Run seed
let seedExe = projectDir / "test" / "seed"
doAssert fileExists(seedExe), "Compile seed first: nim c test/seed.nim"
let (seedOut, seedCode) = execCmdEx(seedExe, workingDir = tmpDir)
echo seedOut.strip()
doAssert seedCode == 0, "Seed failed with code " & $seedCode

# Start server
let serverExe = projectDir / "smplcmts"
doAssert fileExists(serverExe), "Compile server first: nim c -d:release smplcmts.nim"
var server = startProcess(serverExe, workingDir = tmpDir, args = ["-p", $port],
  options = {poStdErrToStdOut})

# Wait for server to be ready
block:
  let c = newHttpClient()
  defer: c.close()
  var ready = false
  for i in 0..50:
    try:
      if c.get(baseUrl & "/").code == Http200:
        ready = true
        break
    except: discard
    sleep(200)
  if not ready:
    server.kill(); server.close()
    removeDir(tmpDir)
    quit("Server failed to start on port " & $port, 1)
echo "Server ready on port ", port

# --- Tests ---

try:
  suite "smplcmts integration":

    # 1. Health check
    test "GET / health check":
      let resp = get("/")
      check resp.code == Http200
      check resp.body == "ok"
      check resp.headers.hasKey("Access-Control-Allow-Origin")
      check resp.headers.hasKey("Access-Control-Allow-Credentials")

    # 2. Static files
    test "GET /smplcmts.css":
      let resp = get("/smplcmts.css")
      check resp.code == Http200
      check "text/css" in $resp.headers["content-type"]

    test "GET /smplcmts.js":
      let resp = get("/smplcmts.js")
      check resp.code == Http200
      check "javascript" in $resp.headers["content-type"]

    # 3. OPTIONS preflight
    test "OPTIONS /comments preflight":
      let resp = options("/comments")
      check resp.code == Http200
      check resp.headers.hasKey("Access-Control-Allow-Methods")

    # 4. GET /comments unauthenticated
    test "GET /comments unauthenticated":
      let resp = get("/comments?site=localhost&url=http://test.com/page")
      check resp.code == Http200
      check "comments" in resp.body
      check resp.headers.hasKey("Access-Control-Allow-Origin")

    # 5. GET /publish unauthenticated
    test "GET /publish unauthenticated shows login form":
      let resp = get("/publish?url=http://test.com/page")
      check resp.code == Http200
      check "email" in resp.body
      check "Receive a link" in resp.body

    # 6. GET /publish authenticated, no username
    test "GET /publish no username shows name form":
      let resp = get("/publish?url=http://test.com/page", cookie = "nosession")
      check resp.code == Http200
      check "Please choose a name" in resp.body

    # 7. POST /name
    test "POST /name sets username":
      let resp = post("/name?site=localhost",
        body = formBody({"username": "TestUser"}),
        cookie = "nosession")
      check resp.code == Http200
      check "Thank you! You are now known as: TestUser" in resp.body

    test "POST /name duplicate for same user":
      # Session still has username="" (not updated), so server tries again.
      # SQLite UPDATE to same value is a no-op, so this may return 200 not 409.
      let resp = post("/name?site=localhost",
        body = formBody({"username": "TestUser"}),
        cookie = "nosession")
      check resp.code in {Http200, Http409}

    test "POST /name duplicate by different user":
      # Create a new user via login flow
      let loginResp = getNoRedirect("/login/testauthtoken2")
      # Extract session cookie from Set-Cookie header
      var newCookie = ""
      if loginResp.headers.hasKey("set-cookie"):
        for val in loginResp.headers["set-cookie"].split(", "):
          if "CommentSessionToken=" in val:
            let start = val.find("CommentSessionToken=") + len("CommentSessionToken=")
            let endP = val.find(';', start)
            newCookie = if endP >= 0: val[start..<endP] else: val[start..^1]
      check newCookie != ""
      # Try to use the same username
      let resp = post("/name?site=localhost",
        body = formBody({"username": "TestUser"}),
        cookie = newCookie)
      check resp.code == Http409
      check "Someone already chose that name!" in resp.body

    # 8. GET /publish authenticated, has username
    test "GET /publish with username shows publish form":
      let resp = get("/publish?url=http://test.com/page", cookie = "testsession")
      check resp.code == Http200
      check "contenteditable" in resp.body

    # 9. POST /publish
    test "POST /publish creates comment":
      let resp = post("/publish?site=localhost",
        body = formBody({"comment": "<b>hello</b>", "url": "http://test.com/page"}),
        cookie = "testsession")
      check resp.code == Http200
      check "you published a comment" in resp.body
      # Verify comment appears
      let comments = get("/comments?site=localhost&url=http://test.com/page")
      check "<b>hello</b>" in comments.body

    # 10. POST /publish with reply-to
    test "POST /publish with reply-to":
      let comments = get("/comments?site=localhost&url=http://test.com/page")
      let commentId = findCommentId(comments.body)
      let resp = post("/publish?site=localhost",
        body = formBody({"comment": "reply text", "url": "http://test.com/page",
                         "reply-to": $commentId}),
        cookie = "testsession")
      check resp.code == Http200
      # Verify reply-to link in comments
      let updated = get("/comments?site=localhost&url=http://test.com/page")
      check "reply-to" in updated.body.toLowerAscii or "Reply to" in updated.body

    # 11. POST /publish invalid HTML
    test "POST /publish rejects script tags":
      let resp = post("/publish?site=localhost",
        body = formBody({"comment": "<script>alert(1)</script>",
                         "url": "http://test.com/page"}),
        cookie = "testsession")
      check resp.code == Http400

    # 12. POST /publish invalid params
    test "POST /publish rejects extra params":
      let resp = post("/publish?site=localhost",
        body = formBody({"comment": "test", "url": "http://test.com/page",
                         "foo": "bar"}),
        cookie = "testsession")
      check resp.code == Http400

    # 13. PUT /cache/comment
    test "PUT /cache/comment stores draft":
      let resp = put("/cache/comment?site=localhost",
        body = formBody({"comment": "<b>draft text</b>", "url": "http://test.com/page"}),
        cookie = "testsession")
      check resp.code == Http200
      # Verify draft shows in publish form
      let publish = get("/publish?url=http://test.com/page", cookie = "testsession")
      check "draft text" in publish.body

    # 14. PUT /cache/reply-to
    test "PUT /cache/reply-to stores and clears":
      let comments = get("/comments?site=localhost&url=http://test.com/page")
      let commentId = findCommentId(comments.body)
      # Set reply-to
      let resp = put("/cache/reply-to?site=localhost",
        body = formBody({"reply-to": $commentId, "url": "http://test.com/page"}),
        cookie = "testsession")
      check resp.code == Http200
      # Verify reply-to shows in publish form
      let publish = get("/publish?url=http://test.com/page", cookie = "testsession")
      check "Replying to" in publish.body
      # Clear reply-to
      let clear = put("/cache/reply-to?site=localhost",
        body = formBody({"reply-to": "", "url": "http://test.com/page"}),
        cookie = "testsession")
      check clear.code == Http200

    # 15. PUT /cache/invalid-key
    test "PUT /cache/foo returns 404":
      let resp = put("/cache/foo?site=localhost",
        body = formBody({"foo": "bar", "url": "http://test.com/page"}),
        cookie = "testsession")
      check resp.code == Http404

    # 16. POST /love/@id
    test "POST /love toggles love":
      let comments = get("/comments?site=localhost&url=http://test.com/page",
        cookie = "testsession")
      let commentId = findCommentId(comments.body)
      # Love
      let love = post("/love/" & $commentId & "?site=localhost",
        cookie = "testsession")
      check love.code == Http200
      let after = get("/comments?site=localhost&url=http://test.com/page",
        cookie = "testsession")
      check "loved" in after.body
      # Unlove (toggle)
      let unlove = post("/love/" & $commentId & "?site=localhost",
        cookie = "testsession")
      check unlove.code == Http200

    # 17. GET /login/@authToken seeded
    test "GET /login/@authToken valid":
      let resp = getNoRedirect("/login/testauthtoken")
      check resp.code in {Http302, Http303}
      check resp.headers.hasKey("set-cookie")
      check "CommentSessionToken=" in $resp.headers["set-cookie"]

    # 18. GET /login/@authToken invalid
    test "GET /login/@authToken bogus":
      let resp = get("/login/bogustoken")
      check resp.code == Http401

    # 19. DELETE /login
    test "DELETE /login logs out":
      sleep(3500)  # wait for IP ban from bogus token test to expire
      let resp = delete("/login", cookie = "testsession")
      check resp.code == Http200
      check "no longer commenting" in resp.body
      # Session should be invalidated - POST /publish requires auth
      let after = post("/publish?site=localhost",
        body = formBody({"comment": "test", "url": "http://test.com/page"}),
        cookie = "testsession")
      check after.code == Http401

    # 20. GET /unsubscribe/@emailHash
    test "GET /unsubscribe unsubscribes":
      let emailHash = "test@test.com"  # not the actual hash, see below
      # The endpoint uses the URL param as the email_hash to look up the user
      # We need the actual saltedHash that was stored
      # Since user 1's email_hash = saltedHash("test@test.com"), use that
      let resp = get("/unsubscribe/" & encodeUrl(saltedHash("test@test.com")) &
        "?site=localhost")
      check resp.code == Http200
      check "no longer receive" in resp.body
      # Again should get 409
      let resp2 = get("/unsubscribe/" & encodeUrl(saltedHash("test@test.com")) &
        "?site=localhost")
      check resp2.code == Http409

    # 21. Auth failure / IP ban
    test "bad session triggers IP ban":
      let resp = get("/comments?site=localhost&url=http://test.com/page",
        cookie = "badcookie")
      # First request with bad cookie - auth fails silently for GET /comments
      # (returns userId -1). AuthError is caught in the route, not propagated.
      # Try a route that requires auth:
      let resp2 = post("/publish?site=localhost",
        body = formBody({"comment": "test", "url": "http://test.com/page"}),
        cookie = "badcookie")
      check resp2.code == Http401
      # Immediate retry should show ban message
      let resp3 = post("/publish?site=localhost",
        body = formBody({"comment": "test", "url": "http://test.com/page"}),
        cookie = "badcookie")
      check resp3.code == Http401
      check "try again" in resp3.body.toLowerAscii or "seconds" in resp3.body
      sleep(4000)  # wait for ban to expire

    # 22. Missing site parameter
    test "GET /comments missing site":
      sleep(1000)  # extra wait for async expiry processing
      if not server.running:
        echo "SERVER DIED! Output:"
        echo server.outputStream.readAll()
        check false
      let health = get("/")
      check health.code == Http200
      let resp = get("/comments?url=http://test.com")
      check resp.code == Http400

finally:
  if server.running:
    server.kill()
  else:
    echo "Server output:"
    echo server.outputStream.readAll()
  server.close()
  echo "Test dir preserved at: ", tmpDir
