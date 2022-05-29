import std/[strutils, re, times, tables, options, parseutils, sugar, smtp]
import jester except error, routeException
import jester/private/utils
import types, database, cache, secret

include "comments.nimf"
include "publish.nimf"
include "name.nimf"
include "signin.nimf"
include "confirm.nimf"

type
  AuthError* = object of ValueError
  Auth = object
    token: string
    user: User

proc auth(request: Request): Auth =
  let header = if request.headers.hasKey("Authorization"):
    request.headers["Authorization"]
  else:
    raise newException(AuthError, "Authorization header required")

  if not header.startsWith("Bearer "):
    raise newException(AuthError, "Authorization header must start with 'Bearer '")

  let token = header[7..^1]

  let txn = dbenv.newTxn()
  discard parseSaturatedNatural(get(txn, dbi, "token $1 userId" % token), result.user.id)
  result.user.username = get(txn, dbi, "userId $1 username" % $result.user.id)
  result.token = token
  txn.abort()


router comments:
  get "/comments":
    iterator comments(): Comment =
      for row in db.iterate(""" SELECT comment.id, timestamp, username, comment, parent_comment_id FROM comment LEFT JOIN user ON comment.user_id=user.id LEFT JOIN url ON comment.url_id=url.id WHERE url=? ORDER BY timestamp """, request.params["url"]):
        yield unpack[Comment](row)
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatComments(comments)

  get "/publish":
    let auth = request.auth
    if auth.user.username == "":
      resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatName()
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatPublish(auth.user.username)
  
  get "/signin":
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatSignin()

  get "/confirm":
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatConfirm()

  get "/name":
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatName()

  post "/signin":
    let pin = generatePassword(8, ['0'..'9'])
    let email = request.params["email"]
    let txn = dbenv.newTxn()
    put(txn, dbi, "signin $1" % saltedHash(email), pin)
    txn.commit()
    let smtp = newAsyncSmtp()
    await smtp.connect("localhost", Port 25)
    try:
      await smtp.sendMail("comments@capocasa.net", @[email], $createMessage("Comments One-Time Password", """
Thank you, here is your one-time password. Please go back to your comments page and enter or copy/paste it.

Your One-Time Password:

$1

""" % pin, @[email]))
    except ReplyError as e:
      resp Http409, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, "Invalid email"
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, email

  post "/confirm":
    let txn = dbenv.newTxn()
    let email = request.params["email"]
    let emailHash = saltedHash(email)
    let key = "signin $1" % emailHash
    let pin = try:
      get(txn, dbi, key)
    except:
      txn.abort()
      resp Http401, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, "No one-time-password sent to %#" % email
    if pin != request.params["pin"]:
      txn.abort()
      resp Http401, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, "One-time-password does not match the one sent to $#" % email
    del(txn, dbi, key, "")
    let value = db.value(""" SELECT id FROM user WHERE email_hash = ? """, emailHash)
    let userId = if value.isSome:
      value.get().fromDbValue(int64)
    else:
      db.exec(""" INSERT INTO user (email_hash) VALUES (?) """, emailHash)
      db.lastInsertRowId()

    let token = generatePassword(128)
    put(txn, dbi, "token $1 userId" % token, $userId)
    put(txn, dbi, "userId $1 username" % $userId, "")
    put(txn, dbi, "userId $1 token" % $userId, token)
    txn.commit()

    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, token

  post "/name":
    let auth = request.auth
    if auth.user.username != "":
      resp Http409, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, "Name already set"
    let username = request.params["username"]
    db.exec(""" UPDATE user SET username = ? WHERE id = ? """, username, auth.user.id)
    let txn = dbenv.newTxn()
    put(txn, dbi, "userId $1 username" % $auth.user.id, username)
    txn.commit()
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, username

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
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, ""

  options re".*":
    resp Http200, {
      "Access-Control-Allow-Headers":"*",
      "Access-Control-Allow-Origin":"*",
      "Access-Control-Allow-Methods":"*"
    }, ""

  get "/comments.js":
    #const clientJs = staticRead("client.js")
    let clientJs = readFile("client.js")
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"application/javascript"}, clientJs

proc errorHandler(request: Request, error: RouteError): Future[ResponseData] {.async.} =
  block route:
    case error.kind:
      of RouteException:
        let e = getCurrentException()
        if e of AuthError:
          resp Http401, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, e.msg
        elif e of ValueError:
          resp Http400, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, e.msg
        else:
          echo e.msg
          echo e.getStackTrace
          resp Http500, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, e.msg
      of RouteCode:
        discard

proc serve*(settings: Settings) =
  var jester = initJester(comments, settings=settings)
  jester.register(errorHandler)
  jester.serve()

