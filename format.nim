
import types, ago, strutils
export types, ago

proc `~`*(s: string): string =
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\n", "<br>")

proc preview*(s: string, length: int): string =

  if s.len > length:
    let i = s.find(' ', 0, s.len)
    if i == -1:
      result = s[0 ..< length]
    else:
      result = s[0 ..< i]
      result.add "…"
  else:
    result = s

