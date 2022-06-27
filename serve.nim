import std/[strutils, re, times, tables, options, parseutils, strscans, smtp, uri]
import jester except error, routeException
import jester/private/utils
import types, database, keyvalue, secret
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
  (kv*, expiry*)  = initKeyValue(config.kvPath)

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
    let u = parseUri(request.headers["referer"])
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

proc abortIfBanned(ip: string) =
  ## Enforce IP ban
  try:
    let bannedUntil = limdb.`[]`(expiry.k2t, "ban $#" % ip).blobToTime  # TODO: why does keyvalue.`[]` not work, stay ambiguous?
    let remaining = bannedUntil - getTime()
    raise newException(AuthError, "Please try again in $# seconds" % $remaining.inSeconds )
  except KeyError:
    # no ban, continue
    discard

template ban(ip: string) =
  ## Simple short IP ban for any auth failure to prevent brute-forcing session or auth tokens.
  ## This is feasible because we use really long ones- therefore, no complex schemes like escalating bans
  ## or captchas are required.
  expiry["ban $#" % ip] = initDuration(seconds=3)

proc auth(request: Request): Auth =

  request.ip.abortIfBanned

  result.sessionToken = if request.cookies.hasKey("SessionToken"):
    request.cookies["SessionToken"]
  else:
    raise newException(AuthError, "Please request a comment link by email to start commenting")

  let t = kv.initTransaction()
  try:
    let value = t["session $#" % saltedHash(result.sessionToken)]
    discard parseSaturatedNatural(value, result.user.id)
    result.user.username = t["userId $# username" % $result.user.id]
  except KeyError:
    request.ip.ban
    raise newException(AuthError, "There is something wrong with your secret comment link, please request a new one by email")
  finally:
    t.reset()

proc base(request: Request): string =
  if request.secure:
    result.add("https://")
    result.add(request.host)
    if request.port != 443:
      result.add(":")
      result.add($request.port)
  else:
    result.add("http://")
    result.add(request.host)
    if request.port != 80:
      result.add(":")
      result.add($request.port)

router comments:
  get "/comments":
    iterator comments(): Comment =
      for row in db.iterate(""" SELECT comment.id, timestamp, username, comment, parent_comment_id FROM comment LEFT JOIN user ON comment.user_id=user.id LEFT JOIN url ON comment.url_id=url.id WHERE url=? ORDER BY timestamp """, request.params["url"]):
        yield unpack[Comment](row)
    resp Http200, formatComments(comments), "text/html;charset=utf-8"

  get "/publish":
    let auth = try:
      request.auth
    except AuthError as e:
      resp Http200,  formatSignin(), "text/html;charset=utf-8"
    if auth.user.username == "":
      resp Http200, formatName(), "text/html; charset=utf-8"
    resp Http200,  formatPublish(auth.user.username), "text/html;charset=utf-8"

  get "/name":
    resp Http200, formatName(), "text/html;charset=utf-8"

  post "/signin":
    request.ip.abortIfBanned
    let authToken = generatePassword(96, ['a'..'z', 'A'..'Z', '0'..'9'])
    let email = request.params["email"]
    let url = request.params["url"]
    kv["signin $#" % saltedHash(authToken)] = "$# $#" % [saltedHash(email), url]
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
    let authValue = try:
      t[authKey]
    except:
      t.reset()
      request.ip.ban
      resp Http401, "No link matching this one was sent recently, please check that it is the right one"
    t.del authKey, authValue
    var emailHash, redirectUrl: string
    assert scanf(authValue, "$+ $+$.", emailHash, redirectUrl), "internal comment email error"
    let row = db.one(""" SELECT id, username FROM user WHERE email_hash = ? """, emailHash)
    let user = if row.isSome:
      unpack[User](row.get)
    else:
      db.exec(""" INSERT INTO user (email_hash) VALUES (?) """, emailHash)
      var user:User
      user.id = db.lastInsertRowId()
      user

    let sessionToken = generatePassword(96, ['a'..'z', 'A'..'Z', '0'..'9'])
    
    let sessionKey = "session $#" % saltedHash(sessionToken)
    t[sessionKey] = $user.id
    t["userId $# username" % $user.id] = user.username
    t.commit()
    expiry[sessionKey] = initDuration(days=7, hours=1) # let cookie expire for security, cleanup token a bit later
    setCookie("SessionToken", sessionToken, expires=daysForward(7), sameSite=None, httpOnly=true,
              path="/",)
    setHeader("Access-Control-Allow-Headers", "Set-Cookie")
    redirect redirectUrl

  post "/name":
    let auth = request.auth
    if auth.user.username != "":
      resp Http409, "You already chose your name"
    let username = request.params["username"]
    try:
      db.exec(""" UPDATE user SET username = ? WHERE id = ? """, username, auth.user.id)
    except SqliteError:
      resp Http409, "Someone already chose that name!"
    kv["userId $# username" % $auth.user.id] = username
    resp Http200, "Thank you! You are now known as: $#" % username

  post "/publish":
    let auth = request.auth
    try:
      db.exec("BEGIN")
      let value = db.value(""" SELECT id FROM url WHERE url = ? """, request.params["url"])
      let url_id = if value == none(DbValue):
        db.exec(""" INSERT INTO url (url) VALUES (?) """, request.params["url"])
        db.lastInsertRowId()
      else:
        value.get().fromDbValue(int)
      db.exec(""" INSERT INTO comment (url_id, user_id, comment) VALUES (?, ?, ?) """, url_id, auth.user.id, request.params["comment"])
      if request.params.hasKey("parent_comment_id"):
        let comment_id = db.lastInsertRowId()
        var parent_comment_id: Natural
        discard parseSaturatedNatural(request.params["parent_comment_id"], parent_comment_id)
        db.exec(""" UPDATE comment SET parent_comment_id = ? WHERE id = ? """, parent_comment_id, comment_id)
    except:
      db.exec("ROLLBACK")
      raise
    db.exec("COMMIT")
    resp Http200, "Thank you, you published a comment!"

  options re".*":
    defaultHeaders()
    resp Http200

  get "/comments.js":
    #const commentJs = staticRead("client.js")
    let js = readFile("comments.js")
    resp Http200, js, "application/javascript"

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
          echo e.msg
          echo e.getStackTrace
          resp Http500, e.msg
      of RouteCode:
        let e = getCurrentException()
        resp Http500, e.msg

proc serve*(settings: Settings) =
  var jester = initJester(comments, settings=settings)
  jester.register(errorHandler)
  jester.serve()

