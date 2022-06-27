import asyncdispatch, times

import limdb, at, at/timeblobs

export limdb, at, timeblobs

# LimDB requires some boilerplate because it only supports strings
iterator keys*(a: limdb.Database): Time =
  for k in limdb.keys(a):
    yield k.blobToTime
proc del*(a: limdb.Database, t: Time) =
  a.del t.timeToBlob

proc `[]`*(a: limdb.Database, t: Time): string =
  limdb.`[]`(a, t.timeToBlob)
proc `[]`*(a: limdb.Database, s: string): Time =
  limdb.`[]`(a, s).blobToTime
proc `[]=`*(a: limdb.Database, t: Time, s: string) =
  limdb.`[]=`(a, t.timeToBlob, s)
proc `[]=`*(a: limdb.Database, s: string, t: Time) =
  limdb.`[]=`(a, s, t.timeToBlob)

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
