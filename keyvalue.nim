import asyncdispatch, times 

import limdb, at

export limdb, at

type
  LimAt = At[Database[Time, string], Database[string, Time]]

proc initKeyValue*(kvPath: string):auto =

  let kv = initDatabase(
    kvPath, (
    main: string,
    t2s: Time, string,
    s2t: string, Time
  ))

  let expiry:LimAt = block:
    proc trigger(t: Time, k: string) =
      try:
        del kv.main, k
      except KeyError:
        discard
    initAt(kv.t2s, kv.s2t)
  asyncCheck expiry.process()
  (kv, expiry)


