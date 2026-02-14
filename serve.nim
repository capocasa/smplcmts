import std/[strutils, times, tables, options, parseutils, uri, sequtils, re, logging, cookies, locks]
import pkg/mummy, pkg/mummy/routers
import pkg/webby
import types, database, keyvalue, mail, secret
import configuration, serialize, sanitize

include "comments.nimf"
include "publish.nimf"
include "name.nimf"
include "login.nimf"

const
  banMilliseconds {.intdefine.} = 3000
  config = initConfig()

var
  lock: Lock
  db: OrderedTable[int, DbConn]
  kv: typeof(initKeyValue(config.kvPath)[0])
  expiry: typeof(initKeyValue(config.kvPath)[1])

initLock(lock)

template withGl(body: untyped) =
  {.gcsafe.}:
    withLock lock:
      body

# Trigger for expiry - defined at module level to avoid closure capture
proc trigger(t: Time, k: string) =
  withGl:
    try:
      del kv.main, k
    except KeyError:
      discard

proc initGlobals*() =
  withGl:
    db = database.initDatabase(config.sqlPath)
    (kv, expiry) = initKeyValue(config.kvPath)
  GC_ref(expiry)
  expiry.process()

proc cleanup*() =
  expiry.stop()

var server*: Server

proc base(uri: Uri): string =
  if uri.scheme != "":
    result.add uri.scheme
    result.add ":"
  if uri.hostname != "":
    result.add("//")
    result.add(uri.hostname)
  if uri.port != "" and uri.port != "80" and uri.port != "443":
    result.add(":")
    result.add(uri.port)

proc parseCookies(request: Request): Table[string, string] =
  result = initTable[string, string]()
  try:
    let cookieHeader = request.headers["cookie"]
    for pair in cookieHeader.split("; "):
      let parts = pair.split("=", 1)
      if parts.len == 2:
        result[parts[0].strip] = parts[1].strip
  except KeyError:
    discard

proc origin(request: Request): string =
  try:
    let u = parseUri(request.headers["origin"])
    result = u.base
  except KeyError, ValueError:
    return "null"
  if result notin config.allowedOrigins:
    return "null"

proc getHeader(headers: HttpHeaders, key: string, default = ""): string =
  try:
    headers[key]
  except KeyError:
    default

proc corsHeaders(request: Request): HttpHeaders =
  result["Access-Control-Allow-Origin"] = request.origin
  result["Access-Control-Allow-Credentials"] = "true"
  result["Access-Control-Allow-Methods"] = "GET, PUT, POST, DELETE, OPTIONS"
  result["Cross-Origin-Resource-Policy"] = "cross-origin"

const textType = "text/plain;charset=utf-8"
const htmlType = "text/html;charset=utf-8"

proc ip(request: Request): string =
  # Try X-Forwarded-For first, then fall back to remoteAddress
  try:
    request.headers["x-forwarded-for"].split(",")[0].strip
  except KeyError:
    request.remoteAddress

proc shortBan(ip: string) =
  withGl:
    expiry["ban $#" % ip] = initDuration(milliseconds=banMilliseconds)

proc abortIfBanned(ip: string) =
  var bannedUntil: Time
  var found = false
  withGl:
    try:
      bannedUntil = expiry.k2t["ban $#" % ip]
      found = true
    except KeyError:
      discard
  if found:
    let remainingMs = (bannedUntil - getTime()).inMilliseconds
    if remainingMs > 0:
      let remainingSec = (remainingMs + 999) div 1000  # Round up to seconds for message
      raise newException(AuthError, "Please try again in $# seconds" % $remainingSec)

proc auth(request: Request): Auth =
  request.ip.abortIfBanned
  let cookies = request.parseCookies
  result.sessionToken = if cookies.hasKey("CommentSessionToken"):
    cookies["CommentSessionToken"]
  else:
    raise newException(AuthError, "Please request a comment link by email to start commenting")
  var notFound = false
  withGl:
    try:
      result.user = kv.session[saltedHash(result.sessionToken)]
    except KeyError:
      notFound = true
  if notFound:
    request.ip.shortBan
    raise newException(AuthError, "There is something wrong with your secret comment link, please request a new one by email")

proc param(request: Request, key: string): string =
  # Check query params first, then form body
  for (k, v) in request.queryParams:
    if k == key:
      return v
  # Parse form body if content-type is form
  if "application/x-www-form-urlencoded" in request.headers.getHeader("content-type", ""):
    for (k, v) in parseSearch(request.body):
      if k == key:
        return v
  raise newException(KeyError, "param not found: " & key)

proc paramOpt(request: Request, key: string): Option[string] =
  try:
    some(request.param(key))
  except KeyError:
    none(string)

proc hasParam(request: Request, key: string): bool =
  request.paramOpt(key).isSome

proc paramKeys(request: Request): seq[string] =
  for (k, v) in request.queryParams:
    result.add k
  if "application/x-www-form-urlencoded" in request.headers.getHeader("content-type", ""):
    for (k, v) in parseSearch(request.body):
      result.add k

proc siteId(request: Request): int =
  let site = request.paramOpt("site")
  if site.isNone:
    raise newException(ValueError, "missing site parameter")
  withGl:
    result = kv.site[site.get]

proc forwardedHost(request: Request): string =
  try:
    request.headers["x-forwarded-host"]
  except KeyError:
    request.headers.getHeader("host", "localhost")

proc forwardedPort(request: Request): int =
  try:
    parseInt(request.headers["x-forwarded-port"])
  except KeyError, ValueError:
    80

proc secure(request: Request): bool =
  request.headers.getHeader("x-forwarded-proto", "http") == "https"

proc base(request: Request): string =
  let port = request.forwardedPort
  let host = request.forwardedHost
  if request.secure:
    result.add("https://")
    result.add(host)
    if port != 443:
      result.add(":")
      result.add($port)
  else:
    result.add("http://")
    result.add(host)
    if port != 80:
      result.add(":")
      result.add($port)

# Cache helper - key serialized as string to avoid tuple pointer issues
proc cacheKeyStr(userId: int, url: string, key: CacheKey): string =
  $userId & "\x1F" & url & "\x1F" & $ord(key)

proc cache(siteId, userId: int, url: string, key: CacheKey, value: string) =
  let cacheKey = cacheKeyStr(userId, url, key)
  withGl:
    if value == "":
      try:
        kv.cache.del cacheKey
      except KeyError:
        discard
    else:
      kv.cache[cacheKey] = value

# Synchronous SMTP helper
proc sendMailSync(fromAddr: string, toAddrs: seq[string], msg: string) =
  var smtp = newSmtp()
  smtp.connect(config.mailHost, Port(config.mailPort))
  try:
    smtp.sendMail(fromAddr, toAddrs, msg)
  finally:
    smtp.close()

# Route handlers

proc healthCheck(request: Request) =
  var headers: HttpHeaders
  headers["Access-Control-Allow-Origin"] = request.origin
  headers["Access-Control-Allow-Credentials"] = "true"
  headers["Access-Control-Allow-Methods"] = "GET, PUT, POST, DELETE, OPTIONS"
  headers["Cross-Origin-Resource-Policy"] = "cross-origin"
  headers["Content-Type"] = "text/plain;charset=utf-8"
  request.respond(200, headers, "ok")

proc getComments(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = htmlType
  var authUserId: int = try:
    request.auth.user.id.int
  except AuthError as e:
    echo e.msg
    -1
  let siteId = request.siteId
  var siteDb: DbConn
  withGl:
    siteDb = db[siteId]
  iterator comments(): Comment =
    for row in siteDb.iterate("""
SELECT
  comment.id,
  comment.timestamp,
  user.username,
  comment.comment,
  GROUP_CONCAT(loved_by.username, CHAR(31)),
  COALESCE(MAX(loved_by.id = ?), 0),
  reply_to.id,
  reply_to.timestamp,
  replyee.username,
  reply_to.comment
FROM
  comment
LEFT JOIN
  user
  ON comment.user_id=user.id
LEFT JOIN
  url
  ON comment.url_id=url.id
LEFT JOIN
  love
  ON love.comment_id=comment.id
LEFT JOIN
  user AS loved_by
  ON love.user_id = loved_by.id
LEFT JOIN
  comment AS reply_to
  ON reply_to.id = comment.reply_to
LEFT JOIN
  user AS replyee
  ON replyee.id=reply_to.user_id
WHERE
  url=?
GROUP BY
  comment.id
ORDER BY
  comment.timestamp,user.username
""", authUserId, request.param("url")):
      var offset = 0
      var comment = unpack[Comment](row, offset, @["id", "timestamp", "name", "comment", "lovedBy", "lovedByMe"])
      comment.lovedBy = comment.lovedBy.deduplicate
      if row[offset].fromDbValue(Option[int]).isSome:
        new(comment.replyTo)
        comment.replyTo[] = unpack[Comment](row, offset, @["id", "timestamp", "name", "comment"])
      yield comment
  var authenticated: bool = try:
    discard request.auth
    true
  except AuthError:
    false
  withGl:
    request.respond(200, headers, formatComments(comments, request.param("url"), authenticated))

proc getPublish(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = htmlType
  let auth = try:
    request.auth
  except AuthError as e:
    request.respond(200, headers, formatLogin())
    return
  if auth.user.username == "":
    request.respond(200, headers, formatName())
    return
  withGl:
    let url = request.param("url")
    let cachedComment = try:
      kv.cache[cacheKeyStr(auth.user.id, url, ckComment)]
    except KeyError:
      ""
    let cachedReplyTo = try:
      some(kv.cache[cacheKeyStr(auth.user.id, url, ckReplyTo)].unserializeReplyTo)
    except KeyError:
      none(Comment)
    request.respond(200, headers, formatPublish(auth.user.username, cachedComment, request.param("url"), cachedReplyTo))

proc getName(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = htmlType
  request.respond(200, headers, formatName())

proc postLogin(request: Request) =
  request.ip.abortIfBanned
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  let authToken = generatePassword(96, ['a'..'z', 'A'..'Z', '0'..'9'])
  let email = request.param("email")
  let url = request.param("url")
  var siteId: int
  withGl:
    siteId = try:
      kv.site[request.param("site")]
    except KeyError:
      request.respond(400, headers, "invalid site")
      return
  let notify = request.hasParam("notify")
  let authHash = saltedHash(authToken)
  withGl:
    kv.login[authHash] = Login(emailHash: saltedHash(email), url: url, notify: if notify: email else: "", siteId: siteId)
    expiry[authHash] = initDuration(hours=1)
  try:
    sendMailSync(config.mailFrom, @[email], $createMessage("Secret Commenting Link", """

Thank you! Please follow this link to start commenting:

$#/login/$#

Please make sure you don't give it to anyone else so no one can comment in your name

""" % [request.base, authToken], @[email]))
  except:
    request.respond(409, headers, "The email could not be sent, please take a look at the address.")
    return
  request.respond(200, headers, """Thank you! Please check your email, you're looking for one called "Secret Commenting Link".""")

proc postSignup(request: Request) =
  request.ip.abortIfBanned
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  let authToken = generatePassword(96, ['a'..'z', 'A'..'Z', '0'..'9'])
  let authHash = saltedHash(authToken)
  let email = request.param("email")
  withGl:
    kv.login[authHash] = Login(emailHash: saltedHash(email), url: "https://comments.capo.casa#moderate", notify: "", siteId: -1)
    expiry[authHash] = initDuration(hours=1)
  try:
    sendMailSync(config.mailFrom, @[email], $createMessage("Welcome To Spot on Comments", """
Thank you for signing up to Spot On Comments!

Please follow this link to receive the code snippet for your web site that will load the comments.

$#/signup/$#

Please make sure you don't give it to anyone else so no one can sign in in your name

""" % [request.base, authToken], @[email]))
  except:
    request.respond(409, headers, "The email could not be sent, please take a look at the address.")
    return
  request.respond(200, headers, """Thank you! Please check your email, you're looking for one called "Welcome To Spot On Comments".""")

proc deleteLogin(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  let auth = request.auth  # auth() is already gcsafe
  withGl:
    kv.session.del saltedHash(auth.sessionToken)
  request.respond(200, headers, "You are now no longer commenting as $#" % auth.user.username)

proc getLoginToken(request: Request) =
  request.ip.abortIfBanned
  var headers: HttpHeaders
  headers["Content-Type"] = textType
  var sessionToken: string
  var login: Login
  var failed = false
  withGl:
    try:
      kv.withTransaction t:
        let authToken = request.pathParams["authToken"]
        let key = saltedHash(authToken)
        login = t.login[key]
        t.login.del key
        let siteDb = db[login.siteId]
        let row = siteDb.one(""" SELECT id, username, email_hash FROM user WHERE email_hash = ? """, login.emailHash)
        let user = if row.isSome:
          unpack[User](row.get)
        else:
          User(id: 0, username: "", emailHash: login.emailHash)
        sessionToken = generatePassword(96, ['a'..'z', 'A'..'Z', '0'..'9'])
        t.session[saltedHash(sessionToken)] = user
        if user.id > 0:
          if login.notify == "":
            try:
              t.notify.del user.id
            except KeyError:
              discard
          else:
            t.notify[user.id] = login.notify
    except KeyError:
      failed = true
  if failed:
    request.ip.shortBan
    request.respond(401, headers, "No link matching this one was sent recently, please check that it is the right one")
    return

  let expiryTime = now() + initDuration(days=7)
  let cookieVal = setCookie("CommentSessionToken", sessionToken, expires=expiryTime.format("ddd',' dd MMM yyyy HH:mm:ss 'GMT'"),
                            sameSite=SameSite.None, httpOnly=true, path="/", secure=true)
  headers["Set-Cookie"] = cookieVal
  headers["Access-Control-Allow-Headers"] = "Set-Cookie"
  headers["Location"] = login.url & "#comment-form"
  request.respond(303, headers, "")

proc postName(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  let auth = request.auth
  let siteId = request.siteId
  if auth.user.username != "":
    request.respond(409, headers, "You already chose your name")
    return
  let username = request.param("username").sanitize
  withGl:
    let siteDb = db[siteId]
    try:
      if auth.user.id == 0:
        siteDb.exec(""" INSERT INTO user (username, email_hash) VALUES (?, ?) """, username, auth.user.emailHash)
        let userId = siteDb.lastInsertRowId()
        kv.session[saltedHash(auth.sessionToken)] = User(id: userId, username: username, emailHash: auth.user.emailHash)
      else:
        siteDb.exec(""" UPDATE user SET username = ? WHERE id = ? """, username, auth.user.id)
        kv.session[saltedHash(auth.sessionToken)] = User(id: auth.user.id, username: username, emailHash: auth.user.emailHash)
    except SqliteError:
      request.respond(409, headers, "Someone already chose that name!")
      return
    kv.main["userId $# username" % $auth.user.id] = username
    request.respond(200, headers, "Thank you! You are now known as: $#" % username)

proc postPublish(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  let auth = request.auth
  let siteId = request.siteId
  for k in request.paramKeys:
    if k notin ["reply-to", "comment", "url", "site"]:
      raise newException(ValueError, "Invalid key $#" % k)
  let url = request.param("url")
  var urlId, commentId: int
  let comment = request.param("comment").sanitizeHtml
  var siteDb: DbConn
  withGl:
    siteDb = db[siteId]
  try:
    siteDb.exec("BEGIN")
    let value = siteDb.value(""" SELECT id FROM url WHERE url = ? """, url)
    urlId = if value.isNone:
      siteDb.exec(""" INSERT INTO url (url) VALUES (?) """, url)
      siteDb.lastInsertRowId()
    else:
      value.get().fromDbValue(int)
    siteDb.exec(""" INSERT INTO comment (url_id, user_id, comment) VALUES (?, ?, ?) """, urlId, auth.user.id, comment)
    commentId = siteDb.lastInsertRowId()
    let replyToOpt = request.paramOpt("reply-to")
    if replyToOpt.isSome:
      var replyTo: Natural
      discard parseSaturatedNatural(replyToOpt.get, replyTo)
      siteDb.exec(""" UPDATE comment SET reply_to = ? WHERE id = ? """, replyTo, commentId)
  except:
    siteDb.exec("ROLLBACK")
    raise
  siteDb.exec("COMMIT")

  for key in [ckComment, ckReplyTo]:
    cache(siteId, auth.user.id, url, key, "")

  # Send notification emails (non-blocking would require a thread pool, keeping sync for now)
  var notifyList: seq[(int, string)]
  for row in siteDb.iterate(""" SELECT DISTINCT user_id, email_hash FROM comment LEFT JOIN user ON user.id=user_id WHERE url_id=? AND user_id !=? """, urlId, auth.user.id):
    notifyList.add row.unpack((int, string))
  for (userId, emailHash) in notifyList:
    var email: string
    withGl:
      email = try:
        kv.main["userId $# notify" % $userId]
      except KeyError:
        continue
    try:
      sendMailSync(config.mailFrom, @[email], $createMessage("New Comment from $#" % auth.user.username, """
$# made a comment:

--
$#
--

See all comments and reply:
$##comment-$#

Unsubscribe:
$#/unsubscribe/$#

""" % [auth.user.username, comment, url, "form", request.base, auth.user.emailHash]))
    except:
      discard  # non-essential, continue

  request.respond(200, headers, "Thank you, you published a comment!")

proc optionsHandler(request: Request) =
  var headers = request.corsHeaders
  request.respond(200, headers, "")

proc postLove(request: Request) =
  var headers = request.corsHeaders
  let auth = request.auth
  let siteId = request.siteId
  var siteDb: DbConn
  withGl:
    siteDb = db[siteId]
  let id = request.pathParams["id"]
  try:
    siteDb.exec("BEGIN")
    let comment_user_id = siteDb.value(""" SELECT user_id FROM comment WHERE id=? """, id)
    let value = siteDb.value(""" SELECT 1 FROM love WHERE user_id=? AND comment_id=? """, auth.user.id, id)
    if value.isSome:
      siteDb.exec(""" DELETE FROM love WHERE user_id=? AND comment_id=? """, auth.user.id, id)
    else:
      siteDb.exec(""" INSERT INTO love (user_id, comment_id) VALUES (?, ?) """, auth.user.id, id)
  except:
    siteDb.exec("ROLLBACK")
    raise
  siteDb.exec("COMMIT")
  request.respond(200, headers, "")

proc putCache(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  let auth = request.auth
  let siteId = request.siteId
  var siteDb: DbConn
  withGl:
    siteDb = db[siteId]
  let url = request.param("url")
  let keyName = request.pathParams["key"]
  let key = case keyName:
    of "comment":
      ckComment
    of "reply-to":
      ckReplyTo
    else:
      request.respond(404, headers, "Cannot cache '$#', must be 'comment' or 'reply-to'" % keyName)
      return
  let value = request.param(keyName)

  if value.len == 0:
    cache(siteId, auth.user.id, url, key, "")
  elif key == ckReplyTo:
    let row = siteDb.one(""" SELECT comment.id, timestamp, username, comment FROM comment LEFT JOIN user ON user_id=user.id WHERE comment.id=? """, value)
    if row.isNone:
      request.respond(409, headers, "reply-to with id $# not found" % value)
      return
    var offset = 0
    let replyTo = unpack[Comment](row.get, offset, @["id", "timestamp", "name", "comment"])
    cache(siteId, auth.user.id, url, key, replyTo.serializeReplyTo)
  else:
    cache(siteId, auth.user.id, url, key, value.sanitizeHtml)

  request.respond(200, headers, "")

proc getUnsubscribe(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  let siteId = request.siteId
  var siteDb: DbConn
  withGl:
    siteDb = db[siteId]
  let emailHash = request.pathParams["emailHash"]
  let value = siteDb.value(""" SELECT id FROM user WHERE email_hash = ? """, emailHash)
  let userId = if value.isSome:
    value.get.fromDbValue(int)
  else:
    -1
  withGl:
    try:
      kv.notify.del userId
    except KeyError:
      request.respond(409, headers, "You already do not receive an email when someone comments.")
      return
  request.respond(200, headers, "You will no longer receive an email when someone comments.")

proc getCss(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = "text/css;charset=utf-8"
  request.respond(200, headers, readFile("smplcmts.css"))

proc getJs(request: Request) =
  var headers = request.corsHeaders
  headers["Content-Type"] = "application/javascript;charset=utf-8"
  request.respond(200, headers, readFile("smplcmts.js"))

proc errorHandler(request: Request, e: ref Exception) =
  var headers = request.corsHeaders
  headers["Content-Type"] = textType
  if e of AuthError:
    request.respond(401, headers, e.msg)
  elif e of ValueError:
    request.respond(400, headers, e.msg)
  else:
    logging.debug e.msg
    logging.debug e.getStackTrace
    request.respond(500, headers, e.msg)

proc serve*(port: int = 5000) =
  initGlobals()
  var router: Router
  router.get("/", healthCheck)
  router.get("/comments", getComments)
  router.get("/publish", getPublish)
  router.get("/name", getName)
  router.post("/login", postLogin)
  router.post("/signup", postSignup)
  router.delete("/login", deleteLogin)
  router.get("/login/@authToken", getLoginToken)
  router.post("/name", postName)
  router.post("/publish", postPublish)
  router.post("/love/@id", postLove)
  router.put("/cache/@key", putCache)
  router.get("/unsubscribe/@emailHash", getUnsubscribe)
  router.get("/smplcmts.css", getCss)
  router.get("/smplcmts.js", getJs)
  # OPTIONS for all paths
  router.options("/**", optionsHandler)

  router.errorHandler = errorHandler

  server = newServer(router)
  echo "Serving on http://localhost:", port
  server.serve(Port(port))
