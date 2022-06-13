import limdb, at

import at, os, asyncdispatch, limdb, times, at/timeblobs

export limdb

# LimDB requires some boilerplate because it only supports strings
iterator keys*(a: limdb.Database): Time =
  for k in limdb.keys(a):
    yield k.blobToTime
proc del*(a: limdb.Database, t: Time) =
  a.del t.timeToBlob

template `[]`*(a: limdb.Database, t: Time): string =
  limdb.`[]`(a, t.timeToBlob)
template `[]`*(a: limdb.Database, s: string): Time =
  limdb.`[]`(a, s.blobToTime)
template `[]=`*(a: limdb.Database, t: Time, s: string) =
  limdb.`[]=`(a, t.timeToBlob, s)
template `[]=`*(a: limdb.Database, s: string, t: Time) =
  limdb.`[]=`(a, s, t.timeToBlob)

proc init*():(Database, At[Database, Database]) =
  let kv = initDatabase(getTempDir() / "limdb", "main")
  proc trigger(t: Time, k: string) =
    kv.del k
  let aa:At[Database, Database] = initAt(kv.initDatabase("at time-to-key"), kv.initDatabase("at key-to-time"))
  asyncCheck aa.process()
  (kv, aa)

