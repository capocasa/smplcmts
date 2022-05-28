
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


