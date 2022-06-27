import times, options

type
  User* = object
    id*: Natural
    username*: string

  Comment* = object
    id*: Natural
    timestamp*: DateTime
    name*: string
    comment*: string
    parent_comment_id*: Option[Natural]
    lovedBy*: seq[string]

