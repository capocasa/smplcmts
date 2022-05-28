import times, options

type
  Comment* = object
    id*: Natural
    timestamp*: DateTime
    name*: string
    comment*: string
    parent_comment_id*: Option[Natural]

  User* = object
    id*: Natural
    username*: string


