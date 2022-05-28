import std/[strutils, re, times, tables, options, parseutils, sugar, smtp]
import jester except error, routeException
import jester/private/utils
import types, database, cache, secret

include "comments.nimf"
include "new.nimf"
include "name.nimf"
include "signin.nimf"
include "confirm.nimf"

type
  AuthError* = object of ValueError

proc auth(request: Request): User =
  let header = if request.headers.hasKey("Authorization"):
    request.headers["Authorization"]
  else:
    raise newException(AuthError, "Authorization header required")

  if not header.startsWith("Bearer "):
    raise newException(AuthError, "Authorization header must start with 'Bearer '")

  let token = header[7..^1]

  let txn = dbenv.newTxn()
  discard parseSaturatedNatural(get(txn, dbi, "token $1 user_id" % token), result.id)
  result.username = get(txn, dbi, "token $1 username" % token)
  txn.abort()


router comments:
  get "/comments":
    iterator comments(): Comment =
      for row in db.iterate(""" SELECT comment.id, timestamp, username, comment, parent_comment_id FROM comment LEFT JOIN user ON comment.user_id=user.id LEFT JOIN url ON comment.url_id=url.id WHERE url=? ORDER BY timestamp """, request.params["url"]):
        yield unpack[Comment](row)
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, format(comments)

  get "/new":
    let user = request.auth
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatNew(user.username)
  
  get "/signin":
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatSignin()

  get "/confirm":
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatConfirm()

  get "/name":
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, formatName()

  post "/signin":
    let pin = generatePassword(8, ['0'..'9'])
    let txn = dbenv.newTxn()
    let email = request.params["email"]
    put(txn, dbi, "signin $1 $2" % [pin, email], "")
    txn.commit()
    let smtp = newAsyncSmtp()
    await smtp.connect("localhost", Port 25)
    await smtp.sendMail("comments@capocasa.net", @[email], $createMessage("pin mail", "pin: $1" % pin, @[email]))
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, ""

  post "/confirm":
    let txn = dbenv.newTxn()
    let email = request.params["email"]
    let key = "signin $1 $2" % [request.params["pin"], email]
    try:
      discard get(txn, dbi, key)
    except:
      txn.abort()
      resp Http401, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, "One-Time-Password %i does not match email address"
    del(txn, dbi, key, "")
    let value = db.value(""" SELECT id FROM user WHERE email = ? """, email)
    let user_id = if value.isSome:
      value.get().fromDbValue(int64)
    else:
      db.exec(""" INSERT INTO user (email) VALUES (?) """, email)
      db.lastInsertRowId()

    let token = generatePassword(128)
    put(txn, dbi, "token $1 user_id" % token, $user_id)
    put(txn, dbi, "token $1 username" % token, "")
    put(txn, dbi, "user_id $1 token" % $user_id, token)
    txn.commit()

    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/plain"}, token
    

  post "/comments":
    let user = request.auth
    try:
      db.exec("BEGIN")
      let value = db.value(""" SELECT id FROM url WHERE url = ? """, request.params["url"])
      let url_id = if value == none(DbValue):
        db.exec(""" INSERT INTO url (url) VALUES (?) """, request.params["url"])
        db.lastInsertRowId()
      else:
        value.get().fromDbValue(int)
      db.exec(""" INSERT INTO comment (url_id, user_id, comment) VALUES (?, ?, ?) """, url_id, user.id, request.params["comment"])
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

