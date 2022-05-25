import times, tiny_sqlite

type
  Comment* = object
    timestamp*: DateTime
    name*: string
    comment*: string

# adding to existing libraries, these could be pull requested
proc unpack*[T: object](row: ResultRow): T =
    var idx = 0
    for name, value in fieldPairs result:
        value = row[idx].fromDbValue(type(value))
        idx.inc

