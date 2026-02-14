
import ../format

assert "<b>foo bar fuz buz</b>".preview(20) == "<b>foo bar fuz buz</b>", "Shorter stays the same"
assert "<b>foo bar fuz buz</b>".preview(10) == "<b>foo bar fu</b>…", "shorten to correct chars, ignoring tags, and add three dots"
assert "<b>foo bar&ouml;fuz buz</b>".preview(10) == "<b>foo baröfu</b>…", "shorten to correct chars, even when cutting entity"

