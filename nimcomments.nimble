# Package

version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "A simple website comment system written in Nim"
license       = "MIT"
bin           = @["nimcomments"]
backend       = "c"

# Dependencies

requires "nim >= 1.6.0"
requires "cligen"
requires "jester#master"
requires "tiny_sqlite"
requires "ago"
requires "lmdb"
