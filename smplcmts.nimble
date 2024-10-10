# Package

version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "A simple and lightweight yet powerful and usable website comment system"
license       = "MIT"
bin           = @["smplcmts"]
backend       = "c"

# Dependencies

requires "nim >= 1.6.0"
requires "cligen"
requires "jester#master"
requires "tiny_sqlite"
requires "ago"
requires "limdb"
requires "at"
requires "smtp"
