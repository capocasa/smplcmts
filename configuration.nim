import smtp

const
  defaultSqlPath {.strdefine.} = "smplcmts.sqlite"
  defaultKvPath {.strdefine.} = "smplcmts.lmdb"

type
  Config* = object
    mailHost*: string
    mailPort*: Port
    mailFrom*: string
    sqlPath*: string
    kvPath*: string
    allowedOrigins*: seq[string]

proc initConfig*(): Config =
  result.mailHost = "localhost"
  result.mailPort = 25.Port
  result.mailFrom = "comments@capocasa.net"
  result.sqlPath = defaultSqlPath
  result.kvPath = defaultKvPath
  result.allowedOrigins = @["https://shamanblog.com", "http://localhost"]


