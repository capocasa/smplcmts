import std/[xmltree, strtabs, streams, sequtils, strutils]
import pkg/[htmlparser]

## Control characters, according to the unicode character property 'Cc'
const controlCharacters =  [0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F, 0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017, 0x0018, 0x0019, 0x001A, 0x001B, 0x001C, 0x001D, 0x001E, 0x001F, 0x007F, 0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x0085, 0x0086, 0x0087, 0x0088, 0x0089, 0x008A, 0x008B, 0x008C, 0x008D, 0x008E, 0x008F, 0x0090, 0x0091, 0x0092, 0x0093, 0x0094, 0x0095, 0x0096, 0x0097, 0x0098, 0x0099, 0x009A, 0x009B, 0x009C, 0x009D, 0x009E, 0x009F].map(proc (v:int):char = v.chr)

proc sanitize*(s: string): string =
  ## Can filter with normal string function because unicode special chars can all be filtered with one byte
  s.filterIt(it notin controlCharacters).join()

proc parse(html: string, errors: var seq[string]): XmlNode =
  var errors: seq[string] = @[]
  result = parseHtml(newStringStream(html), "unknown_html_doc", errors)

proc validate(node: XmlNode) =
  case node.kind:
    of xnElement:
      case node.tag
      of "b", "i", "br", "strike", "document":
        if node.attrsLen > 0:
          raise newException(ValueError, "No HTML attributes allowed for $#" % $node)
      of "a":
        if node.attrsLen != 1 or not node.attrs.hasKey("href"):
          raise newException(ValueError, "<a> tag must have an href attribute and no others but found: $#" % $node)
      else:
        raise newException(ValueError, "Only b, i, br, s and a elements allowed but found $#" % $node)
      for n in node:
        validate(n)
    of xnText:
      discard
    else:
      raise newException(ValueError, "Only text and HTML elements allowed but found $#" % $node)

proc str(node: XmlNode): string =
  if node.kind == xnElement and node.tag == "document":
    for n in node:  # append string value for children but not document element itself
      result.add(replace($n, " />", ">"))  # nasty hack to avoid XML closing tags, we're using HTML5
  else:
    result = replace($node, " />", ">")

proc sanitizeHtml*(html: string): string =
  ## Sanitize HTML. Parses and regenerates it so it's valid,
  ## and a ValueError is raised if it doesn't conform to our
  ## comment subset of HTML

  var errors: seq[string] = @[]
  let root = parseHtml(newStringStream(html), "unknown_html_doc", errors)
  if errors.len > 0:
    raise newException(ValueError, "Cannt parse HTML, $#" % errors.join(", "))
  root.validate
  root.str

proc regenHtml*(html: string): string =
  ## Parse and regenerate HTML to close tags etc but do not
  ## validate
  parseHtml(html).str

