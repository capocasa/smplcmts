import asyncdispatch, times, strutils

import limdb, at

export limdb, at

# LimDB requires some boilerplate because it only supports strings
iterator keys*(a: limdb.Database): Time =
  for k in limdb.keys(a):
    yield k.parseFloat.fromUnixFloat
proc del*(a: limdb.Database, t: Time) =
  a.del $t.toUnixFloat

# TODO: consider using at's binary serialization
# with a custom comparison function that sorts these properly
proc `[]`*(a: limdb.Database, t: Time): string =
  limdb.`[]`(a, $t.toUnixFloat)
proc `[]`*(a: limdb.Database, s: string): Time =
  limdb.`[]`(a, s).parseFloat.fromUnixFloat
proc `[]=`*(a: limdb.Database, t: Time, s: string) =
  limdb.`[]=`(a, $t.toUnixFloat, s)
proc `[]=`*(a: limdb.Database, s: string, t: Time) =
  limdb.`[]=`(a, s, $t.toUnixFloat)

proc initKeyValue*(kvPath: string):(Database, At[Database, Database]) =
  let kv = initDatabase(kvPath, "kv")
  let expiry:At[Database, Database] = block:
    proc trigger(t: Time, k: string) =
      try:
        kv.del k
      except KeyError:
        discard
    initAt(kv.initDatabase("expiry"), kv.initDatabase("expiry_"))
  asyncCheck expiry.process()
  (kv, expiry)
