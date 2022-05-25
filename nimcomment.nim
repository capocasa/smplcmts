
import os, strutils
import cligen/parseopt3
import database, serve

from jester import newSettings
from nativesockets import Port

var settings = newSettings()

var p = initOptParser(shortNoVal = {'v', 'h'}, longNoVal = @["version", "help"])
for kind, key, val in p.getopt():
  # echo "kind: ", $kind, " key: ", $key, " val: ", $val
  case kind
  of cmdShortOption, cmdLongOption:
    case key:
    of "h", "help":
      echo """Usage: nimcomment [ARGUMENT] [OPTION]

Comment server

                      Without argument, start server
initdb                Initialize database. This is destructive.
dropdb                Delete database. This is destructive.

-v, --version         display version and quit
-h, --help            display this help and quit
-p, --port            port number 
"""
      quit 0
    of "v", "version":
      echo "0.1.0" 
      quit 0
    of "p", "port":
      settings.port = parseInt(val).Port
    else:
      stderr.writeLine("Invalid option '$#'" % val)
      quit 1
  of cmdArgument:
    case key:
    of "initdb":
      initDb()
      quit 0
    of "dropdb":
      dropDb()
      quit 0
    else:
      stderr.writeLine("Invalid argument '$#'$" % key)
      quit 2
  of cmdError:
    stderr.writeLine("Invalid syntax: $#" % commandLineParams().join(" "))
    quit 12
  of cmdEnd:
    discard

serve(settings)
