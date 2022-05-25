
import tiny_sqlite
import times
from os import removeFile

export tiny_sqlite

const dbPath = "nimcomment.sqlite"

let db* = openDatabase(dbPath)

db.exec("PRAGMA foreign_keys = OFF")

proc initDb*() =
  db.execScript("""
    CREATE TABLE user(
      id INTEGER PRIMARY KEY,
      username TEXT NOT NULL,
      email TEXT NOT NULL,
      UNIQUE(username),
      UNIQUE(email)
    );
    CREATE UNIQUE INDEX idx_user_username ON user(`username`);
    CREATE UNIQUE INDEX idx_user_email ON user(`email`);
    CREATE TABLE otp(
      user_id INTEGER NOT NULL,
      otp INTEGER NOT NULL,
      timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
      PRIMARY KEY (user_id, otp),
      FOREIGN KEY(user_id) REFERENCES `user`(id) DEFERRABLE INITIALLY DEFERRED
    );
    CREATE INDEX idx_user_id ON otp(`user_id`);
    CREATE INDEX idx_otp_timestamp ON otp('timestamp');
    CREATE INDEX idx_otp_otp ON otp('otp');
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
      comment_id INTEGER,
      timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
      comment TEXT NOT NULL,
      FOREIGN KEY(url_id) REFERENCES `url`(id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(user_id) REFERENCES `user`(id) DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY(comment_id) REFERENCES `comment`(id) DEFERRABLE INITIALLY DEFERRED
    );
    CREATE INDEX idx_comment_url_id ON comment('url_id');
    CREATE INDEX idx_comment_user_id ON comment('user_id');
    CREATE INDEX idx_comment_comment_id ON comment('comment_id');
    CREATE INDEX idx_comment_timestamp ON comment('timestamp');
  """)

proc dropDb*() =
  removeFile(dbPath)

proc toDbValue*(t: DateTime): DbValue =
  DbValue(kind: sqliteInteger, intVal: t.toTime.toUnix)

proc fromDbValue*(val: DbValue, T: typedesc[DateTime]): DateTime =
  val.intVal.fromUnix.utc

proc toDbValue*(w: Weekday): DbValue =
  DbValue(kind: sqliteInteger, intVal: w.int64)

proc fromDbValue*(val: DbValue, T: typedesc[Weekday]): Weekday =
  val.intVal.Weekday

