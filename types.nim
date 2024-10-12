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

