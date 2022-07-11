import times

type
  User* = object
    id*: Natural
    username*: string

  Comment* = object
    id*: Natural
    timestamp*: DateTime
    name*: string
    comment*: string
    lovedBy*: seq[string]
    replyTo*: ref Comment

