
import tiny_sqlite
import times
from os import removeFile

export tiny_sqlite

proc initDatabase*(sqlPath: string): DbConn =
  result = openDatabase(sqlPath)
  result.exec("PRAGMA foreign_keys = OFF")

proc initDb*(db: DbConn) =
  db.execScript("""

CREATE TABLE user(
  --
  -- A user authenticated by sending a token to an email address.
  -- Only a hash of the email address and a freely-chosend username is stored to avoid
  -- storing any personal data because privacy matters and if this gets hacked there is nothing to find.

  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL DEFAULT '',
  email_hash TEXT NOT NULL,
  UNIQUE(username),
  UNIQUE(email_hash)
);
CREATE UNIQUE INDEX idx_user_username ON user(username);
CREATE UNIQUE INDEX idx_user_email_hash ON user(email_hash);


CREATE TABLE url(
  --
  -- The URL of the page where a group of comments are.
  -- This is expected to be an absolute one but this is not enforced
  -- in the backend, any unique string would work fine.

  id INTEGER PRIMARY KEY,
  url TEXT NOT NULL,
  UNIQUE(url)
);
CREATE UNIQUE INDEX idx_url_url ON url(url);


CREATE TABLE comment(
  --
  -- stores- surprise! comments.
  --
  -- while having a parent-child 1:n table would usually require
  -- slow/cumbersome recursive queries and some kind of graph
  -- database should be used, here it is ok because
  -- we only ever want to display the immediate child along with the
  -- parent. This would need to be migrated or cached if this requirement
  -- changes.

  id INTEGER PRIMARY KEY,
  url_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  comment TEXT NOT NULL,
  reply_to INTEGER,
  FOREIGN KEY(url_id) REFERENCES url(id) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY(user_id) REFERENCES "user"(id) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY(reply_to) REFERENCES comment(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX idx_comment_url_id ON comment('url_id');
CREATE INDEX idx_comment_user_id ON comment('user_id');
CREATE INDEX idx_comment_timestamp ON comment('timestamp');
CREATE INDEX idx_comment_reply_to ON comment('reply_to');


CREATE TABLE love(
  --
  -- we think we will never require other reactions than "love" because
  -- this is minimalistic, but if this changes, this data will have to be migrated.

  user_id INTEGER NOT NULL,
  comment_id INTEGER NOT NULL,
  PRIMARY KEY(user_id, comment_id),
  FOREIGN KEY(user_id) REFERENCES "user"(id) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY(comment_id) REFERENCES comment(id) DEFERRABLE INITIALLY DEFERRED
);

  """)

proc dropDb*(sqlPath: string) =
  removeFile(sqlPath)

proc toDbValue*(t: DateTime): DbValue =
  DbValue(kind: sqliteInteger, intVal: t.toTime.toUnix)

proc fromDbValue*(val: DbValue, T: typedesc[DateTime]): DateTime =
  val.intVal.fromUnix.utc

proc toDbValue*(w: Weekday): DbValue =
  DbValue(kind: sqliteInteger, intVal: w.int64)

proc fromDbValue*(val: DbValue, T: typedesc[Weekday]): Weekday =
  val.intVal.Weekday

proc fromDbValue*(val: DbValue, T: typedesc[seq[string]]): seq[string]=
  if val.kind == sqliteNull:
    @[]
  else:
    val.fromDbValue(string).split(chr(31))

# add features to tiny_sqlite

template unpack*[T: object](row: ResultRow, offset = 0): T =
  # workaround- how the heck do I write a static[seq[string]] literal
  # to supply as default value for the proc below? TODO: find out
  const skip: seq[string] = @[]
  var o = offset
  unpack[T](row, o, skip)

proc unpack*[T: object](row: ResultRow, offset: var int, limit_to: static[seq[string]]): T =
  for name, value in fieldPairs result:
    when limit_to.len == 0 or name in limit_to:
      value = row[offset].fromDbValue(type(value))
      offset.inc

#[
proc unpack*[T: object](row: ResultRow): T =
  var offset = 0
  for name, value in fieldPairs result:
    when name notin skip:
      value = row[offset].fromDbValue(type(value))
      offset.inc
]#

