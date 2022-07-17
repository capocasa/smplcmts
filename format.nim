
import std/strutils
import ago
import types, sanitize
export types, ago

proc `~`*(s: string): string =
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\n", "<br>")

proc preview*(s: string, length: int): string =
  ## generate a shortened preview for our
  ## html subset for comments. perfectly valid
  ## html is assumed.

  if s.len < length:
    # we know we don't need to shorten
    # no matter how many tags might be in there
    return s

  # we might or might not need to shorten
  # but there is no way to know without scanning
  # for tags

  var
    i = 0
    j = 0
    inTag = false
    inEntity = false
  while i < s.len and j < length:
    if s[i] == '<':
      inTag = true
    if s[i] == '&':
      inEntity = true
    if inEntity and s[i] == ';':
      # inEntity set to false before increasing j,
      # j will increase once per enitity
      inEntity = false
    if not inTag and not inEntity:
      j += 1
    if s[i] == '>':
      # inTag set to false after increasing j,
      # j will not increase per tag
      inTag = false
    i += 1

  result = s[0 ..< i].regenHtml

  if j == length:
    result.add "…"

