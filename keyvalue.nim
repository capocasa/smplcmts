import asyncdispatch, times, strutils

import limdb, at

export limdb, at

type
  LimAt = At[Database[Time, string], Database[string, Time]]

proc initKeyValue*(kvPath: string):(Database[string,string], LimAt) =

  let l = initDatabase(kvPath, (kv: string, t2s: Time, string, s2t: string, Time))

  let expiry:LimAt = block:
    proc trigger(t: Time, k: string) =
      try:
        del l.kv, k
      except KeyError:
        discard
    initAt(l.t2s, l.s2t)
  asyncCheck expiry.process()
  (l.kv, expiry)


