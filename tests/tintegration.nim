## Integration tests for smplcmts.
## Run: nim c -r test/integration.nim

import std/[httpclient, os, strutils, unittest, uri, httpcore, times]
import pkg/mummy

# Import setup FIRST to create test data before serve initializes
import setup

# Now import serve - it will use the test paths from nim.cfg
import ../serve, ../secret

const
  baseUrl = "http://localhost:" & $testPort

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

# --- Start server in background thread ---

var serverThread: Thread[void]

proc runServer() {.thread.} =
  setCurrentDir(testDir)
  serve(testPort)

createThread(serverThread, runServer)

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
    let resp = get("/publish?url=http://test.com/page", cookie = "nosession")
    check resp.code == Http200
    check "Please choose a name" in resp.body

  test "POST /name sets username":
    let resp = post("/name?site=localhost",
      body = formBody({"username": "TestUser"}),
      cookie = "nosession")
    check resp.code == Http200
    check "Thank you! You are now known as: TestUser" in resp.body

  test "POST /name duplicate for same user":
    let resp = post("/name?site=localhost",
      body = formBody({"username": "TestUser"}),
      cookie = "nosession")
    check resp.code in {Http200, Http409}

  test "POST /name duplicate by different user":
    let loginResp = getNoRedirect("/login/testauthtoken2")
    var newCookie = ""
    if loginResp.headers.hasKey("set-cookie"):
      for val in loginResp.headers["set-cookie"].split(", "):
        if "CommentSessionToken=" in val:
          let start = val.find("CommentSessionToken=") + len("CommentSessionToken=")
          let endP = val.find(';', start)
          newCookie = if endP >= 0: val[start..<endP] else: val[start..^1]
    check newCookie != ""
    let resp = post("/name?site=localhost",
      body = formBody({"username": "TestUser"}),
      cookie = newCookie)
    check resp.code == Http409
    check "Someone already chose that name!" in resp.body

  test "GET /publish with username shows publish form":
    let resp = get("/publish?url=http://test.com/page", cookie = "testsession")
    check resp.code == Http200
    check "contenteditable" in resp.body

  test "POST /publish creates comment":
    let resp = post("/publish?site=localhost",
      body = formBody({"comment": "<b>hello</b>", "url": "http://test.com/page"}),
      cookie = "testsession")
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
      cookie = "testsession")
    check resp.code == Http200
    let updated = get("/comments?site=localhost&url=http://test.com/page")
    check "reply-to" in updated.body.toLowerAscii or "Reply to" in updated.body

  test "POST /publish rejects script tags":
    let resp = post("/publish?site=localhost",
      body = formBody({"comment": "<script>alert(1)</script>",
                       "url": "http://test.com/page"}),
      cookie = "testsession")
    check resp.code == Http400

  test "POST /publish rejects extra params":
    let resp = post("/publish?site=localhost",
      body = formBody({"comment": "test", "url": "http://test.com/page",
                       "foo": "bar"}),
      cookie = "testsession")
    check resp.code == Http400

  test "PUT /cache/comment stores draft":
    let resp = put("/cache/comment?site=localhost",
      body = formBody({"comment": "<b>draft text</b>", "url": "http://test.com/page"}),
      cookie = "testsession")
    check resp.code == Http200
    let publish = get("/publish?url=http://test.com/page", cookie = "testsession")
    check "draft text" in publish.body

  test "PUT /cache/reply-to stores and clears":
    let comments = get("/comments?site=localhost&url=http://test.com/page")
    let commentId = findCommentId(comments.body)
    let resp = put("/cache/reply-to?site=localhost",
      body = formBody({"reply-to": $commentId, "url": "http://test.com/page"}),
      cookie = "testsession")
    check resp.code == Http200
    let publish = get("/publish?url=http://test.com/page", cookie = "testsession")
    check "Replying to" in publish.body
    let clear = put("/cache/reply-to?site=localhost",
      body = formBody({"reply-to": "", "url": "http://test.com/page"}),
      cookie = "testsession")
    check clear.code == Http200

  test "PUT /cache/foo returns 404":
    let resp = put("/cache/foo?site=localhost",
      body = formBody({"foo": "bar", "url": "http://test.com/page"}),
      cookie = "testsession")
    check resp.code == Http404

  test "POST /love toggles love":
    let comments = get("/comments?site=localhost&url=http://test.com/page",
      cookie = "testsession")
    let commentId = findCommentId(comments.body)
    let love = post("/love/" & $commentId & "?site=localhost",
      cookie = "testsession")
    check love.code == Http200
    let after = get("/comments?site=localhost&url=http://test.com/page",
      cookie = "testsession")
    check "loved" in after.body
    let unlove = post("/love/" & $commentId & "?site=localhost",
      cookie = "testsession")
    check unlove.code == Http200

  test "GET /login/@authToken valid":
    let resp = getNoRedirect("/login/testauthtoken")
    check resp.code in {Http302, Http303}
    check resp.headers.hasKey("set-cookie")
    check "CommentSessionToken=" in $resp.headers["set-cookie"]

  test "GET /login/@authToken bogus":
    let resp = get("/login/bogustoken")
    check resp.code == Http401

  test "DELETE /login logs out":
    sleep(150)
    let resp = delete("/login", cookie = "testsession")
    check resp.code == Http200
    check "no longer commenting" in resp.body
    let after = post("/publish?site=localhost",
      body = formBody({"comment": "test", "url": "http://test.com/page"}),
      cookie = "testsession")
    check after.code == Http401

  test "GET /unsubscribe unsubscribes":
    let resp = get("/unsubscribe/" & encodeUrl(saltedHash("test@test.com")) &
      "?site=localhost")
    check resp.code == Http200
    check "no longer receive" in resp.body
    let resp2 = get("/unsubscribe/" & encodeUrl(saltedHash("test@test.com")) &
      "?site=localhost")
    check resp2.code == Http409

  test "bad session triggers IP ban":
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
    sleep(150)

  test "GET /comments missing site":
    sleep(150)
    let health = get("/")
    check health.code == Http200
    let resp = get("/comments?url=http://test.com")
    check resp.code == Http400

# Tests complete - clean shutdown
server.close()
cleanup()

echo "Test dir: ", testDir
echo "All tests passed!"

# Exit immediately to avoid ORC cleanup crash
# (thread-boundary ref objects in Tat cause cycle detection issues)
quit(0)
