
# this is mainly here to temporarily store form data after each keystroke
# it probably doesn't matter at the likely scale of usage, but it just seems
# like such bad fit for sqllite to write to the darn file and block comment loading
# whenever someone presses a key. Hence, way overkill but lovely, lmdb.

# could do it on the client but it will just be such a pleasant surprise when
# someone finds a half-finished comment already there when loading on another device

import std/os, lmdb

export lmdb

createDir("nimcomments.cache")
let dbenv* = newLMDBEnv("nimcomments.cache")
let dummy_txn = dbenv.newTxn()  # lmdb quirk, need an initial txn to open dbi that can be kept
let dbi*  = dummy_txn.dbiOpen("", 0)
dummy_txn.commit()



