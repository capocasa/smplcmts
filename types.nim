import times

type
  User* = object
    id*: Natural
    username*: string
    emailHash*: string

  Comment* = object
    id*: Natural
    timestamp*: DateTime
    name*: string
    comment*: string
    lovedBy*: seq[string]
    lovedByMe*: bool
    replyTo*: ref Comment

  AuthError* = object of ValueError
  Auth* = object
    user*: User
    sessionToken*: string
  Login* = object
    emailHash*: string
    url*: string
    notify*: string
    siteId*: int

  CacheKey* = enum
    ckComment, ckReplyTo

