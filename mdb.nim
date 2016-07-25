from posix import mkdir
import private.bitmasks

{.passl: "-llmdb".}
const LMDB = "<lmdb.h>"

const debug = is_main_module
when debug:
    from strutils import to_hex, align
    proc `$`(p: pointer): string =
        if p == nil: "nil"
        else: "0x" & cast[int](p).to_hex

#--------------------------------------------------------------------------
# C values and types

bitmask Environment_flags_set, Environment_flags, cuint:
    fixed_map    = 0x00_00_00_01
    no_sub_dir   = 0x00_00_40_00
    no_sync      = 0x00_01_00_00
    rd_only      = 0x00_02_00_00
    no_meta_sync = 0x00_04_00_00
    write_map    = 0x00_08_00_00
    map_async    = 0x00_10_00_00
    no_tls       = 0x00_20_00_00
    no_lock      = 0x00_40_00_00
    no_rd_ahead  = 0x00_80_00_00
    no_mem_init  = 0x01_00_00_00

bitmask Transaction_flags_set, Transaction_flags, cuint:
    rd_only      = 0x00_02_00_00

type Mode = distinct posix.Mode
converter degrade_mode(mode: Mode): auto = posix.Mode(mode)

type MDB_env {.importc, pure, final, incompletestruct.} = object
type MDB_txn {.importc, pure, final, incompletestruct.} = object
type Error = distinct cint
converter is_error(err: Error): bool = err.cint != 0

#--------------------------------------------------------------------------
# Nim types

type Environment* = ptr MDB_env
type Transaction* = ptr MDB_txn
type Database_error* = object of Exception

#--------------------------------------------------------------------------
# C API

proc mdb_strerror(err: Error): cstring
    {.importc, header: LMDB.}
proc mdb_version(major, minor, patch: var cint): cstring
    {.importc, header: LMDB.}

proc mdb_env_create(env: var Environment): Error
    {.importc, header: LMDB.}
proc mdb_env_open(env: Environment, path: cstring, flags: cuint, mode: Mode): Error
    {.importc, header: LMDB.}
proc mdb_env_close(env: Environment)
    {.importc, header: LMDB.}

proc mdb_txn_begin(env: Environment, parent: Transaction, flags: cuint, txn: var Transaction)
    {.importc, header: LMDB.}
proc mdb_txn_commit(txn: Transaction)
    {.importc, header: LMDB.}
proc mdb_txn_abort(txn: Transaction)
    {.importc, header: LMDB.}

#--------------------------------------------------------------------------
# utils

proc check(err: Error) {.raises: [Database_error].} =
    if err: raise Database_error.new_exception($mdb_strerror(err))

#--------------------------------------------------------------------------
# system

proc version*(): (int, int, int, string) =
    var major, minor, patch: cint
    let verstr = mdb_version(major, minor, patch)
    (major.int, minor.int, patch.int, $verstr)

#--------------------------------------------------------------------------
# environment

proc open*(path: string, flags: Environment_flags_set, mode: Mode): Environment =
    mdb_env_create(result).check
    mdb_env_open(result, path, flags, mode).check

proc open*(path: string, readonly = false, dir_mode = 0o755.Mode, env_mode = 0o644.Mode): Environment =
    var flags = {}.Environment_flags_set
    if readonly: flags.incl Environment_flags.rd_only
    discard mkdir(path, dir_mode)       # FIXME: should I care about it?
    open(path, flags, env_mode)

proc close*(env: Environment) =
    mdb_env_close(env)

#--------------------------------------------------------------------------
# transaction

proc begin*(env: Environment, flags: Transaction_flags_set, parent: Transaction = nil): Transaction =
    mdb_txn_begin(env, parent, flags, result)

proc begin*(env: Environment, read_only = false, parent: Transaction = nil): Transaction =
    var flags = {}.Transaction_flags_set
    if read_only: flags.incl Transaction_flags.rd_only
    begin(env, flags, parent)

proc commit*(txn: Transaction) = mdb_txn_commit(txn)
proc abort*(txn: Transaction) = mdb_txn_abort(txn)

template transaction_scope_guard(txn, body: untyped): untyped =
    when debug: echo "TXN ", "BEGAN".align(8), " ", txn

    var failed = false
    try:
        body
    except:
        failed = true
        raise
    finally:
        if failed:
            abort(txn)
            when debug: echo "TXN ", "ABORTED".align(8), " ", txn
        else:
            commit(txn)
            when debug: echo "TXN ", "COMMITED".align(8), " ", txn

template transaction*(env: Environment; txn, body: untyped): untyped =
    let txn = begin(env)
    transaction_scope_guard(txn, body)

#--------------------------------------------------------------------------
# example

when is_main_module:
    let t: tuple[major, minor, patch: int; str: string] = version()
    echo "version", $t
    echo()

    let db = open "./test"
    echo "DB OPENED ", db
    echo()

    try:
        transaction db, txn:
            raise new_exception(Exception, "should have aborted")
    except:
        echo get_current_exception_msg()
    echo()

    block TEST:
        transaction db, txn:
            echo "should commit"
            break TEST
    echo()

    db.close
    echo "DB CLOSED ", db
    echo()
    echo GC_get_statistics()

