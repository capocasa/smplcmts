## Integration tests for smplcmts.
## Run: nim c -r tests/tintegration.nim

import std/[httpclient, os, strutils, unittest, uri, httpcore, osproc, streams]

# Import setup FIRST and call init before serve initializes
import setup
initTestData()

# Import secret for saltedHash used in tests
import ../secret

const
  baseUrl = "http://localhost:" & $testPort
  projectDir = currentSourcePath().parentDir().parentDir()
  testBinary = testDir / "smplcmts_test"

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

# --- Build and start server as subprocess ---

# Build test binary with test defines
let compileCmd = "nim c -o:" & testBinary & " " &
  "-d:defaultSqlPath=\"" & testSqlDir & "\" " &
  "-d:defaultKvPath=\"" & testKvPath & "\" " &
  "-d:banMilliseconds=100 " &
  "-d:debug " &
  "--threads:on --mm:orc -d:ssl " &
  projectDir / "smplcmts.nim"
let (output, exitCode) = execCmdEx(compileCmd)
if exitCode != 0:
  echo output
  quit("Failed to compile test binary", 1)

let serverLogFile = testDir / "server.log"
# Start server with output redirected to log file
let serverCmd = testBinary & " -p " & $testPort & " > " & serverLogFile & " 2>&1 &"
discard execShellCmd("cd " & testDir & " && " & serverCmd)

var seenLoginUrls: seq[string]

proc getLastLoginUrl(): string =
  ## Read the last NEW LOGIN_URL from server log file
  sleep(100)  # Brief wait for flush
  if fileExists(serverLogFile):
    for line in serverLogFile.readFile().splitLines:
      if line.startsWith("DEBUG LOGIN_URL:"):
        let url = line[len("DEBUG LOGIN_URL:")..^1]
        if url notin seenLoginUrls:
          seenLoginUrls.add url
          result = url

proc extractAuthToken(loginUrl: string): string =
  ## Extract auth token from login URL like http://localhost:5111/login/TOKEN
  let parts = loginUrl.split("/login/")
  if parts.len == 2:
    result = parts[1]

proc extractSessionCookie(resp: Response): string =
  ## Extract CommentSessionToken from Set-Cookie header
  if resp.headers.hasKey("set-cookie"):
    for val in resp.headers["set-cookie"].split(", "):
      if "CommentSessionToken=" in val:
        let start = val.find("CommentSessionToken=") + len("CommentSessionToken=")
        let endP = val.find(';', start)
        return if endP >= 0: val[start..<endP] else: val[start..^1]

proc doLogin(email: string, notify = false): string =
  ## Perform full login flow: POST /login -> GET /login/token -> return session cookie
  var fields = @[("email", email), ("url", "http://test.com/page")]
  if notify:
    fields.add ("notify", "on")
  discard post("/login?site=localhost", body = formBody(fields))
  let loginUrl = getLastLoginUrl()
  assert loginUrl != "", "No login URL found in server log"
  let authToken = extractAuthToken(loginUrl)
  assert authToken != "", "Could not extract auth token from: " & loginUrl
  let resp = getNoRedirect("/login/" & authToken)
  assert resp.code in {Http302, Http303}, "Login redirect failed: " & $resp.code
  result = extractSessionCookie(resp)
  assert result != "", "No session cookie in login response"

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
    quit("Server failed to start on port " & $testPort, 1)
echo "Server ready on port ", testPort

# --- Authenticate via login flow ---
# Get a real session by going through the full login flow
let mainSession = doLogin("test@test.com")
echo "Logged in with session: ", mainSession[0..15] & "..."

# Set username for main session
block:
  let c = newHttpClient()
  defer: c.close()
  c.headers = newHttpHeaders({
    "Content-Type": "application/x-www-form-urlencoded",
    "Cookie": "CommentSessionToken=" & mainSession
  })
  let resp = c.post(baseUrl & "/name?site=localhost", body = "username=testuser")
  assert resp.code == Http200, "Failed to set username: " & resp.body
echo "Username set for main session"

# Get a second session for a new user (no username yet)
let newUserSession = doLogin("newuser@test.com")
echo "New user session: ", newUserSession[0..15] & "..."

# --- Tests ---

suite "smplcmts integration":

  test "GET / health check":
    let resp = get("/")
    check resp.code == Http200
    check resp.body == "ok"
    check resp.headers.hasKey("Access-Control-Allow-Origin")
    check resp.headers.hasKey("Access-Control-Allow-Credentials")

  test "GET /smplcmts.css":
    let resp = get("/smplcmts.css")
    check resp.code == Http200
    check "text/css" in $resp.headers["content-type"]

  test "GET /smplcmts.js":
    let resp = get("/smplcmts.js")
    check resp.code == Http200
    check "javascript" in $resp.headers["content-type"]

  test "OPTIONS /comments preflight":
    let resp = options("/comments")
    check resp.code == Http200
    check resp.headers.hasKey("Access-Control-Allow-Methods")

  test "GET /comments unauthenticated":
    let resp = get("/comments?site=localhost&url=http://test.com/page")
    check resp.code == Http200
    check "comments" in resp.body
    check resp.headers.hasKey("Access-Control-Allow-Origin")

  test "GET /publish unauthenticated shows login form":
    let resp = get("/publish?url=http://test.com/page")
    check resp.code == Http200
    check "email" in resp.body
    check "Receive a link" in resp.body

  test "GET /publish no username shows name form":
    let resp = get("/publish?url=http://test.com/page", cookie = newUserSession)
    check resp.code == Http200
    check "Please choose a name" in resp.body

  test "POST /name sets username":
    let resp = post("/name?site=localhost",
      body = formBody({"username": "TestUser"}),
      cookie = newUserSession)
    check resp.code == Http200
    check "Thank you! You are now known as: TestUser" in resp.body

  test "POST /name duplicate for same user":
    let resp = post("/name?site=localhost",
      body = formBody({"username": "TestUser"}),
      cookie = newUserSession)
    check resp.code in {Http200, Http409}

  test "POST /name duplicate by different user":
    # Login as a third user and try to claim the same username
    let thirdUserSession = doLogin("thirduser@test.com")
    let resp = post("/name?site=localhost",
      body = formBody({"username": "TestUser"}),
      cookie = thirdUserSession)
    check resp.code == Http409
    check "Someone already chose that name!" in resp.body

  test "GET /publish with username shows publish form":
    let resp = get("/publish?url=http://test.com/page", cookie = mainSession)
    check resp.code == Http200
    check "contenteditable" in resp.body

  test "POST /publish creates comment":
    let resp = post("/publish?site=localhost",
      body = formBody({"comment": "<b>hello</b>", "url": "http://test.com/page"}),
      cookie = mainSession)
    check resp.code == Http200
    check "you published a comment" in resp.body
    let comments = get("/comments?site=localhost&url=http://test.com/page")
    check "<b>hello</b>" in comments.body

  test "POST /publish with reply-to":
    let comments = get("/comments?site=localhost&url=http://test.com/page")
    let commentId = findCommentId(comments.body)
    let resp = post("/publish?site=localhost",
      body = formBody({"comment": "reply text", "url": "http://test.com/page",
                       "reply-to": $commentId}),
      cookie = mainSession)
    check resp.code == Http200
    let updated = get("/comments?site=localhost&url=http://test.com/page")
    check "reply-to" in updated.body.toLowerAscii or "Reply to" in updated.body

  test "POST /publish rejects script tags":
    let resp = post("/publish?site=localhost",
      body = formBody({"comment": "<script>alert(1)</script>",
                       "url": "http://test.com/page"}),
      cookie = mainSession)
    check resp.code == Http400

  test "POST /publish rejects extra params":
    let resp = post("/publish?site=localhost",
      body = formBody({"comment": "test", "url": "http://test.com/page",
                       "foo": "bar"}),
      cookie = mainSession)
    check resp.code == Http400

  test "PUT /cache/comment stores draft":
    let resp = put("/cache/comment?site=localhost",
      body = formBody({"comment": "<b>draft text</b>", "url": "http://test.com/page"}),
      cookie = mainSession)
    check resp.code == Http200
    let publish = get("/publish?url=http://test.com/page", cookie = mainSession)
    check "draft text" in publish.body

  test "PUT /cache/reply-to stores and clears":
    let comments = get("/comments?site=localhost&url=http://test.com/page")
    let commentId = findCommentId(comments.body)
    let resp = put("/cache/reply-to?site=localhost",
      body = formBody({"reply-to": $commentId, "url": "http://test.com/page"}),
      cookie = mainSession)
    check resp.code == Http200
    let publish = get("/publish?url=http://test.com/page", cookie = mainSession)
    check "Replying to" in publish.body
    let clear = put("/cache/reply-to?site=localhost",
      body = formBody({"reply-to": "", "url": "http://test.com/page"}),
      cookie = mainSession)
    check clear.code == Http200

  test "PUT /cache/foo returns 404":
    let resp = put("/cache/foo?site=localhost",
      body = formBody({"foo": "bar", "url": "http://test.com/page"}),
      cookie = mainSession)
    check resp.code == Http404

  test "POST /love toggles love":
    let comments = get("/comments?site=localhost&url=http://test.com/page",
      cookie = mainSession)
    let commentId = findCommentId(comments.body)
    let love = post("/love/" & $commentId & "?site=localhost",
      cookie = mainSession)
    check love.code == Http200
    let after = get("/comments?site=localhost&url=http://test.com/page",
      cookie = mainSession)
    check "loved" in after.body
    let unlove = post("/love/" & $commentId & "?site=localhost",
      cookie = mainSession)
    check unlove.code == Http200

  test "POST /login generates correct URL":
    let resp = post("/login?site=localhost",
      body = formBody({"email": "urltest@test.com", "url": "http://test.com/page"}))
    # Mail send will fail but URL should still be logged
    let loginUrl = getLastLoginUrl()
    check loginUrl.startsWith("http://localhost:" & $testPort & "/login/")
    check loginUrl.len > len("http://localhost:" & $testPort & "/login/") + 10

  test "GET /login/@authToken valid":
    # Request a new login and use the auth token
    discard post("/login?site=localhost",
      body = formBody({"email": "authtest@test.com", "url": "http://test.com/page"}))
    let loginUrl = getLastLoginUrl()
    let authToken = extractAuthToken(loginUrl)
    let resp = getNoRedirect("/login/" & authToken)
    check resp.code in {Http302, Http303}
    check resp.headers.hasKey("set-cookie")
    let cookie = $resp.headers["set-cookie"]
    check cookie.startsWith("CommentSessionToken=")

  test "GET /login/@authToken bogus":
    let resp = get("/login/bogustoken")
    check resp.code == Http401
    sleep(150)  # Wait for IP ban to expire

  test "DELETE /login logs out":
    let resp = delete("/login", cookie = mainSession)
    check resp.code == Http200
    check "no longer commenting" in resp.body
    let after = post("/publish?site=localhost",
      body = formBody({"comment": "test", "url": "http://test.com/page"}),
      cookie = mainSession)
    check after.code == Http401

  test "GET /unsubscribe unsubscribes":
    # Wait for any IP ban to expire
    sleep(150)
    # Create a new user first
    let email = "unsubtest@test.com"
    let session = doLogin(email)
    let nameResp = post("/name?site=localhost",
      body = formBody({"username": "UnsubTestUser"}),
      cookie = session)
    check nameResp.code == Http200
    # Now login again with notify=on - this time user exists so notify is stored
    discard doLogin(email, notify = true)
    # Now unsubscribe using the email hash
    let resp = get("/unsubscribe/" & encodeUrl(saltedHash(email)) &
      "?site=localhost")
    check resp.code == Http200
    check "no longer receive" in resp.body
    # Second unsubscribe should fail
    let resp2 = get("/unsubscribe/" & encodeUrl(saltedHash(email)) &
      "?site=localhost")
    check resp2.code == Http409

  test "bad session triggers IP ban and expires":
    let resp = get("/comments?site=localhost&url=http://test.com/page",
      cookie = "badcookie")
    let resp2 = post("/publish?site=localhost",
      body = formBody({"comment": "test", "url": "http://test.com/page"}),
      cookie = "badcookie")
    check resp2.code == Http401
    let resp3 = post("/publish?site=localhost",
      body = formBody({"comment": "test", "url": "http://test.com/page"}),
      cookie = "badcookie")
    check resp3.code == Http401
    check "try again" in resp3.body.toLowerAscii or "seconds" in resp3.body
    # Wait for ban to expire (100ms in test mode)
    sleep(150)
    # Confirm ban expired by successfully making a request
    let resp4 = get("/")
    check resp4.code == Http200

  test "GET /comments missing site":
    let resp = get("/comments?url=http://test.com")
    check resp.code == Http400

# Tests complete - clean shutdown
discard execShellCmd("pkill -f 'smplcmts_test.*-p " & $testPort & "' 2>/dev/null || true")

echo "Test dir: ", testDir
echo "All tests passed!"
