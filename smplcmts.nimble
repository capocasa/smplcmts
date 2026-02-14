# Package

version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "A simple and lightweight yet powerful and usable website comment system"
license       = "MIT"
bin           = @["smplcmts"]
backend       = "c"

# Dependencies

requires "nim >= 2.0.0"
requires "cligen"
requires "mummy >= 0.4.0"
requires "webby >= 0.2.0"
requires "tiny_sqlite"
requires "ago >= 0.1.0"
requires "limdb"
requires "at >= 0.1.0"
requires "smtp"
requires "htmlparser"
