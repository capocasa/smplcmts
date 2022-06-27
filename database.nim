
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
      id INTEGER PRIMARY KEY,
      username TEXT NOT NULL DEFAULT "",
      email_hash TEXT NOT NULL,
      UNIQUE(username),
      UNIQUE(email_hash)
    );
    CREATE UNIQUE INDEX idx_user_username ON user(`username`);
    CREATE UNIQUE INDEX idx_user_email_hash ON user(`email_hash`);
    CREATE TABLE url(
      id INTEGER PRIMARY KEY,
      url TEXT NOT NULL,
      UNIQUE(url)
    );
    CREATE UNIQUE INDEX idx_url_url ON url(`url`);
    CREATE TABLE comment(
      id INTEGER PRIMARY KEY,
      url_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      parent_comment_id INTEGER,
      timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
      comment TEXT NOT NULL,
      FOREIGN KEY(url_id) REFERENCES `url`(id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(user_id) REFERENCES `user`(id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(parent_comment_id) REFERENCES `comment`(id) DEFERRABLE INITIALLY DEFERRED
    );
    CREATE INDEX idx_comment_url_id ON comment('url_id');
    CREATE INDEX idx_comment_user_id ON comment('user_id');
    CREATE INDEX idx_comment_parent_comment_id ON comment('parent_comment_id');
    CREATE INDEX idx_comment_timestamp ON comment('timestamp');
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


# add features to tiny_sqlite
proc unpack*[T: object](row: ResultRow): T =
    var idx = 0
    for name, value in fieldPairs result:
        value = row[idx].fromDbValue(type(value))
        idx.inc

