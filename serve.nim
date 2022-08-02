import std/[strutils, re, times, tables, options, parseutils, strscans, smtp, uri, logging, sequtils]
import jester except error, routeException
import jester/private/utils
import types, database, keyvalue, secret, sanitize, serialize
import configuration

include "comments.nimf"
include "publish.nimf"
include "name.nimf"
include "signin.nimf"

type
  AuthError* = object of ValueError
  Auth = object
    user: User
    sessionToken: string

const
  config = initConfig()

let
  db* = database.initDatabase(config.sqlPath)
  (kv*, expiry*) = initKeyValue(config.kvPath)

proc base(uri: Uri): string =
  if uri.scheme != "":
    result.add uri.scheme
    result.add ":"
  if uri.hostname != "":
    result.add("//")
    result.add(uri.hostname)
  if uri.port != "":
    result.add(":")
    result.add(uri.port)

proc origin(request: Request): string =
  try:
    let u = parseUri(request.headers["origin"])
    result = u.base
  except KeyError, ValueError:
    return "null"
  if result notin config.allowedOrigins:
    return "null"  # TODO: error message here

template setHeader(key, value: string) =
  setHeader(result[2], key, value)

template defaultHeaders() =
  setHeader("Access-Control-Allow-Origin", request.origin)
  setHeader("Access-Control-Allow-Credentials", "true")
  setHeader("Access-Control-Allow-Methods", "GET, PUT, POST, DELETE, OPTIONS")

template resp*(code: HttpCode) =
  defaultHeaders()
  jester.resp code

template resp*(code: HttpCode, content: string,
               contentType = "text/plain;charset=utf-8") =
  defaultHeaders()
  jester.resp code, content, contentType

template redirect(url: string, halt = true) =
  defaultHeaders()
  jester.redirect(url, halt)

template shortBan(ip: string) =
  ## Simple short IP ban for any auth failure to prevent brute-forcing session or auth tokens.
  ## This is feasible because we use really long ones- therefore, no complex schemes like escalating bans
  ## or captchas are required.
  {.cast(gcsafe)}:
    expiry["ban $#" % ip] = initDuration(seconds=3)

proc abortIfBanned(ip: string) =
  ## Enforce IP ban
  try:
    let bannedUntil = limdb.`[]`(expiry.k2t, "ban $#" % ip).parseFloat.fromUnixFloat # TODO: why does keyvalue.`[]` not work, stay ambiguous?
    let remaining = bannedUntil - getTime()
    raise newException(AuthError, "Please try again in $# seconds" % $remaining.inSeconds )
  except KeyError:
    # no ban, continue
    discard

proc auth(request: Request): Auth =

  request.ip.abortIfBanned

  result.sessionToken = if request.cookies.hasKey("CommentSessionToken"):
    request.cookies["CommentSessionToken"]
  else:
    raise newException(AuthError, "Please request a comment link by email to start commenting")

  let t = kv.initTransaction()
  try:
    let value = t["session $#" % saltedHash(result.sessionToken)]
    discard parseSaturatedNatural(value, result.user.id)
    result.user.username = t["userId $# username" % $result.user.id]
  except KeyError:
    t.reset()
    request.ip.shortBan
    raise newException(AuthError, "There is something wrong with your secret comment link, please request a new one by email")
  except:
    t.reset()
    raise
  t.reset()

template forwardedHost(request: Request): string =
  try:
    $request.headers["x-forwarded-host"]
  except KeyError:
    request.host

template forwardedPort(request: Request): int =
  try:
    parseInt request.headers["x-forwarded-port"]
  except KeyError:
    request.port

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

router comments:

  get "/":
    resp Http200, "ok"

  get "/comments":
    let authUserId = try:
      request.auth.user.id.int
    except AuthError:
      -1
    iterator comments(): Comment =
      # note the delimiter ascii-31 is used which is not allowed
      # by the sanitizer and historic usage fits well semantically
      for row in db.iterate("""
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
""", authUserId, request.params["url"]):
        var offset = 0
        var comment = unpack[Comment](row, offset, @["id", "timestamp", "name", "comment", "lovedBy", "lovedByMe"])
        # sqlite could do this with GROUP_CONCAT(DISTINCT ...) but then the delimiter would have to be the default ,
        comment.lovedBy = comment.lovedBy.deduplicate
        if row[offset].fromDbValue(Option[int]).isSome:
          new(comment.replyTo)
          comment.replyTo[] = unpack[Comment](row, offset, @["id", "timestamp", "name", "comment"])
        yield comment
    let authenticated = try:
      discard request.auth
      true
    except AuthError:
      false
    resp Http200, formatComments(comments, request.params["url"], authenticated), "text/html;charset=utf-8"

  get "/publish":
    let auth = try:
      request.auth
    except AuthError as e:
      resp Http200,  formatSignin(), "text/html;charset=utf-8"
    if auth.user.username == "":
      resp Http200, formatName(), "text/html; charset=utf-8"
    let cachedComment = try:
      limdb.`[]`(kv,"cache $# $# comment" % [$auth.user.id, request.params["url"]])
    except KeyError:
      ""
    let cachedReplyTo = try:
      limdb.`[]`(kv, "cache $# $# reply-to" % [$auth.user.id, request.params["url"]]).unserializeReplyTo().some
    except KeyError:
      none(Comment)

    resp Http200, formatPublish(auth.user.username, cachedComment, request.params["url"], cachedReplyTo), "text/html;charset=utf-8"

  get "/name":
    resp Http200, formatName(), "text/html;charset=utf-8"

  post "/signin":
    request.ip.abortIfBanned
    let authToken = generatePassword(96, ['a'..'z', 'A'..'Z', '0'..'9'])
    let email = request.params["email"]
    let url = request.params["url"]
    let signinKey = "signin $#" % saltedHash(authToken)
    kv[signinKey] = "$# $#" % [saltedHash(email), url]
    expiry[signinKey] = initDuration(hours=1)
    let smtp = newAsyncSmtp()
    await smtp.connect(config.mailHost, Port config.mailPort)
    let link = "$#/confirm/$#" % [request.base, authToken]
    try:
      await smtp.sendMail(config.mailFrom, @[email], $createMessage("Secret Commenting Link", """

Thank you! Please follow this link to start commenting:

$#

Please make sure you don't give it to anyone else so no one can comment in your name

""" % link, @[email]))
    except ReplyError as e:
      resp Http409, "The email could not be sent, please take a look at the address."

    resp Http200, """Thank you! Please check your email, you're looking for one called "Secret Commenting Link"."""

  delete "/signin":
    let auth = request.auth
    let t = kv.initTransaction()
    let key = "session $#" % saltedHash(auth.sessionToken)
    let value = t[key]
    t.del key
    t.commit()
    resp Http200, "You are now no longer commenting as $#" % auth.user.username

  get "/confirm/@authToken":
    request.ip.abortIfBanned
    let authKey = "signin $#" % saltedHash(@"authToken")
    let t = kv.initTransaction()
    var sessionToken, sessionKey: string
    var emailHash, redirectUrl: string
    try:
      db.exec("BEGIN")
      let authValue = try:
        t[authKey]
      except:
        t.reset()
        db.exec("ROLLBACK")
        request.ip.shortBan
        resp Http401, "No link matching this one was sent recently, please check that it is the right one"
      t.del authKey, authValue
      assert scanf(authValue, "$+ $+$.", emailHash, redirectUrl), "internal comment email error"
      let row = db.one(""" SELECT id, username FROM user WHERE email_hash = ? """, emailHash)
      let user = if row.isSome:
        unpack[User](row.get)
      else:
        db.exec(""" INSERT INTO user (email_hash) VALUES (?) """, emailHash)
        var user:User
        user.id = db.lastInsertRowId()
        user

      sessionToken = generatePassword(96, ['a'..'z', 'A'..'Z', '0'..'9'])
      sessionKey = "session $#" % saltedHash(sessionToken)
      t[sessionKey] = $user.id
      t["userId $# username" % $user.id] = user.username
    except:
      t.reset()
      db.exec("ROLLBACK")
      raise
    t.commit()
    db.exec("COMMIT")
    expiry[sessionKey] = initDuration(days=7, hours=1) # let cookie expire for security, cleanup token a bit later
    setCookie("CommentSessionToken", sessionToken, expires=daysForward(7), sameSite=Strict, httpOnly=true,
              path="/",secure=true)
    setHeader("Access-Control-Allow-Headers", "Set-Cookie")
    redirect redirectUrl & "#comment-form"

  post "/name":
    let auth = request.auth
    if auth.user.username != "":
      resp Http409, "You already chose your name"
    let username = request.params["username"].sanitize
    try:
      db.exec(""" UPDATE user SET username = ? WHERE id = ? """, username, auth.user.id)
    except SqliteError:
      resp Http409, "Someone already chose that name!"
    kv["userId $# username" % $auth.user.id] = username
    resp Http200, "Thank you! You are now known as: $#" % username

  post "/publish":
    let auth = request.auth
    for k in request.params.keys:
      if k notin ["reply-to", "comment", "url"]:
        raise newException(ValueError, "Invalid key $#" % k)
    try:
      db.exec("BEGIN")
      let value = db.value(""" SELECT id FROM url WHERE url = ? """, request.params["url"])
      let url_id = if value.isNone:
        db.exec(""" INSERT INTO url (url) VALUES (?) """, request.params["url"])
        db.lastInsertRowId()
      else:
        value.get().fromDbValue(int)
      db.exec(""" INSERT INTO comment (url_id, user_id, comment) VALUES (?, ?, ?) """, url_id, auth.user.id, request.params["comment"].sanitizeHtml)
      if request.params.hasKey("reply-to"):
        let commentId = db.lastInsertRowId()
        var replyTo: Natural
        discard parseSaturatedNatural(request.params["reply-to"], replyTo)
        db.exec(""" UPDATE comment SET reply_to = ? WHERE id = ? """, replyTo, commentId)
    except:
      db.exec("ROLLBACK")
      raise
    db.exec("COMMIT")
    
    for key in ["reply-to", "comment"]:
      cache(auth.user.id, request.params["url"], key, "")

    resp Http200, "Thank you, you published a comment!"

  options re".*":
    defaultHeaders()
    resp Http200

  post "/love/@id":
    let auth = request.auth
    try:
      db.exec("BEGIN")
      let comment_user_id = db.value(""" SELECT user_id FROM comment WHERE id=? """, @"id")
      let value = db.value(""" SELECT 1 FROM love WHERE user_id=? AND comment_id=? """, auth.user.id, @"id")
      if value.isSome:
        db.exec(""" DELETE FROM love WHERE user_id=? AND comment_id=? """, auth.user.id, @"id")
      else:
        db.exec(""" INSERT INTO love (user_id, comment_id) VALUES (?, ?) """, auth.user.id, @"id")
    except:
      db.exec("ROLLBACK")
      raise
    db.exec("COMMIT")
    resp Http200
 
  proc cache(user_id: int, url, key, value: string) =
    ## cache an ephemeral user-generated value in key-value store
    ## empty string as value deletes it
    let cacheKey = "cache $# $# $#" % [$user_id, url, key]
    if value == "":
      try:
        limdb.del(kv, cacheKey)
      except KeyError:
        discard
    else:
      kv[cacheKey] = value
    if expiry.k2t.hasKey(cacheKey):
      # workaround for yet unexplored mixin conflict
      limdb.del expiry.t2k, limdb.`[]`(expiry.k2t, cacheKey)
      limdb.del expiry.k2t, cacheKey
    if value != "":
      # if not deleting schedule long expiry
      expiry[cacheKey] = initDuration(days=30)

  put "/cache/@key":
    let auth = request.auth
    let key = @"key"
    case key:
    of "comment", "reply-to":
      discard
    else:
      resp Http404, "Cannot cache '$#', must be 'comment' or 'reply-to'" % @"key"
    let value = request.params[key]

    if key == "reply-to" and value.len > 0:
      # reply-to: cache entire reply
      let row = db.one(""" SELECT comment.id, timestamp, username, comment FROM comment LEFT JOIN user ON user_id=user.id WHERE comment.id=? """, value)
      if row.isNone:
        resp Http409, "reply-to with id $# not found" % value
      var offset = 0
      let replyTo = unpack[Comment](row.get, offset, @["id", "timestamp", "name", "comment"])
      cache(auth.user.id, request.params["url"], key, replyTo.serializeReplyTo())
    else:
      # comment: cache as sanitized html
      cache(auth.user.id, request.params["url"], key, value.sanitizeHtml)

    resp Http200

proc errorHandler(request: Request, error: RouteError): Future[ResponseData] {.async.} =
  block route:
    case error.kind:
      of RouteException:
        let e = getCurrentException()
        if e.isNil:
          resp Http500, "unknown internal error"
        if e of AuthError:
          resp Http401, e.msg
        elif e of ValueError:
          resp Http400, e.msg
        else:
          logging.debug e.msg
          logging.debug e.getStackTrace
          resp Http500, e.msg
      of RouteCode:
        discard

proc serve*(settings: Settings) =
  var jester = initJester(comments, settings=settings)
  jester.register(errorHandler)
  jester.serve()

