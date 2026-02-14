import std/[times,strutils]
import pkg/[limdb,tat]
import types

export limdb, tat

# Time serialization for LMDB
template toBlob*(t: Time): Blob =
  let timeStr = $t.toUnix & "." & $t.nanosecond
  Blob(mvSize: timeStr.len.uint, mvData: cast[pointer](timeStr.cstring))

proc fromBlob*(b: Blob, T: typedesc[Time]): Time =
  let s = fromBlob(b, string)
  let parts = s.split('.')
  result = fromUnix(parts[0].parseBiggestInt)
  if parts.len > 1:
    result += initDuration(nanoseconds = parts[1].parseInt)

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
  LimTat = Tat[Database[Time, string], Database[string, Time]]

proc initKeyValue*(kvPath: string):auto =

  let kv = initDatabase(
    kvPath, (
    main: string,
    site: string, int,
    cache: string, string,  # key serialized as "userId\x1Furl\x1FcacheKey"
    login: string, Login,
    session: string, User,
    notify: int, string,
    t2s: Time, string,
    s2t: string, Time
  ))

  let expiry:LimTat = initTat(kv.t2s, kv.s2t)
  # Don't call expiry.process() here - the trigger would capture kv as a closure,
  # which breaks {.thread.}. Instead, serve.nim defines trigger using its global kv
  # and calls expiry.process() after initGlobals.
  (kv, expiry)

