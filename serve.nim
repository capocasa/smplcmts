import std/[json, strutils, base64, re, times, tables]
import jester except error, routeException
import jester/private/utils
import database, common, format
type
  AuthError* = object of ValueError

proc auth(request: Request) =
  let header = try:
    request.headers["Authorization"]
  except KeyError:
    raise newException(AuthError, "Authorization header required")
  
  if header.len < 6:
    raise newException(AuthError, "Àuthorization header too short")

  if header[0..6].toLowerAscii == "basic ":
    raise newException(AuthError, "Basic auth required")

  let auth = header[6..header.high].decode.strip(chars={'='}).split(":")

  let username = "carlo"
  let password = "1234"

  if len(auth) != 2:
    raise newException(AuthError, "Decoded base auth must contain exactly one colon : to seperate username and password")
  if auth[0] != username:
    raise newException(AuthError, "Invalid username")
  if auth[1] != password:
    raise newException(AuthError, "Invalid password")

router comments:
  get "/comments":
    iterator comments(): Comment =
      for row in db.iterate(""" SELECT timestamp, username, comment FROM comment LEFT JOIN user ON comment.user_id=user.id LEFT JOIN url ON comment.url_id=url.id WHERE url=? ORDER BY timestamp """, request.params["url"]):
        yield unpack[Comment](row)
    resp Http200, {"Access-Control-Allow-Origin":"*", "Content-Type":"text/html"}, format(comments)

  post "/comments":
    request.auth
    echo $request.headers
    echo $request.params
    resp Http200, {"Access-Control-Allow-Origin":"*"}, ""

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
          resp Http401, {"Access-Control-Allow-Origin":"*", "Content-Type":"application/json"}, e.msg
        elif e of ValueError:
          resp Http400, {"Access-Control-Allow-Origin":"*", "Content-Type":"application/json"}, e.msg
        else:
          raise e
      of RouteCode:
        discard

proc serve*(settings: Settings) =
  var jester = initJester(comments, settings=settings)
  jester.register(errorHandler)
  jester.serve()

