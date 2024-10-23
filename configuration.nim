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
  result.sqlPath = "smplcmts.sqlite"
  result.kvPath = "smplcmts.lmdb"
  result.allowedOrigins = @["https://shamanblog.com", "http://localhost"]


