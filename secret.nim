
import std/[sysrand]


proc generatePassword*(length: Natural = 64, ranges: openarray[Slice[char]] = ['!'..'~']):string =
    # password generator modeled after what you can do on the command line:
    # < /dev/urandom tr -dc '!-~' | head -c64
    # TODO: it would be nice to waste fewer random bytes by getting only the amounts of bits needed
    # and deriving the characters from them. This works for now.
    let span = block:
      var s = 0
      for range in ranges:
        echo $range
        s += len(range)
      s
    echo "SPAN ", $span
    # get twice as many random bytes per chunk as we would need statistically,
    # so we mostly only need to call for them once
    let chunksize = 2 * length * 255 div span 
    var i = chunksize
    var bytes:seq[byte]
    while result.len < length:
      if i == chunksize:
        i = 0
        bytes = urandom(chunksize)
      else:
        i += 1
      for range in ranges:
        if bytes[i].char in range:
          result.add(chr(bytes[i]))
          break


# borrowed from https://rosettacode.org/wiki/SHA-256#Nim

import strutils
const SHA256Len = 32
proc SHA256(d: cstring, n: culong, md: cstring = nil): cstring {.cdecl, dynlib: "libssl.so", importc.}
proc SHA256*(s: string): string =
  result = ""
  let s = SHA256(s.cstring, s.len.culong)
  for i in 0 .. SHA256Len - 1:
    result.add s[i].BiggestInt.toHex(2).toLower

proc saltedHash*(s: string): string =
  SHA256("!+E@/IQ<ci~mWS>7-g,t*A$dKW&0UH)1PcxN}$Fzeo=}ofMGtUk.Xk*fwG/ett7B" & s)

