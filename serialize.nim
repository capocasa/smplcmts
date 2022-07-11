
import std/[times, strutils]

import types

proc serializeReplyTo*(comment: Comment): string =
  result.add $comment.id
  result.add chr(31)
  result.add $comment.timestamp.toTime.toUnixFloat
  result.add chr(31)
  result.add comment.name
  result.add chr(31)
  result.add comment.comment

proc unserializeReplyTo*(s: string): Comment =
  echo s
  let p = s.split(chr(31))
  result.id = p[0].parseInt
  result.timestamp = p[1].parseFloat.fromUnixFloat.utc
  result.name = p[2]
  result.comment = p[3]


