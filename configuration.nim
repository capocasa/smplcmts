import smtp

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
  result.sqlPath = "nimcomments.sqlite"
  result.kvPath = "nimcomments.lmdb"
  result.allowedOrigins = @["http://localhost"]


