import std/[asyncdispatch,times,strutils]
import pkg/[limdb, at]
import types

export limdb, at

# Custom toBlob/fromBlob for types containing strings.
# LimDB's generic object serialization stores raw pointers which
# become dangling across process boundaries.

template toBlob*(u: User): Blob =
  let serializedUser = $u.id & "\x1F" & u.username & "\x1F" & u.emailHash
  Blob(mvSize: serializedUser.len.uint, mvData: cast[pointer](serializedUser.cstring))

proc fromBlob*(b: Blob, T: typedesc[User]): User =
  let s = fromBlob(b, string)
  let parts = s.split('\x1F')
  result.id = parts[0].parseInt
  result.username = parts[1]
  result.emailHash = parts[2]

template toBlob*(l: Login): Blob =
  let serializedLogin = l.emailHash & "\x1F" & l.url & "\x1F" & l.notify & "\x1F" & $l.siteId
  Blob(mvSize: serializedLogin.len.uint, mvData: cast[pointer](serializedLogin.cstring))

proc fromBlob*(b: Blob, T: typedesc[Login]): Login =
  let s = fromBlob(b, string)
  let parts = s.split('\x1F')
  result.emailHash = parts[0]
  result.url = parts[1]
  result.notify = parts[2]
  result.siteId = parts[3].parseInt

type
  LimAt = At[Database[Time, string], Database[string, Time]]

proc initKeyValue*(kvPath: string):auto =

  let kv = initDatabase(
    kvPath, (
    main: string,
    site: string, int,
    cache: (int, string, CacheKey), string,
    login: string, Login,
    session: string, User,
    notify: int, string,
    t2s: Time, string,
    s2t: string, Time
  ))

  let expiry:LimAt = block:
    proc trigger(t: Time, k: string) =
      try:
        del kv.main, k
        # just deleting in both is very dirty
        # but databases keys are single digits
        # so we will fix later
        # TODO: make this capable of expiring any key in here
        # probably requires expanding At
        # del kv.site, k
        # del kv.login, k
      except KeyError:
        discard
    initAt(kv.t2s, kv.s2t)
  asyncCheck expiry.process()
  (kv, expiry)

