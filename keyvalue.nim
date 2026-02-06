import std/[asyncdispatch,times]
import pkg/[limdb, at]
import types

export limdb, at

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

