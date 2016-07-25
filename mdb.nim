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

bitmask Database_flags_set, Database_flags, cuint:
    reverse_key  = 0x00_00_00_02
    dup_sort     = 0x00_00_00_04
    integer_key  = 0x00_00_00_08
    dup_fixed    = 0x00_00_00_10
    integer_dup  = 0x00_00_00_20
    reverse_dup  = 0x00_00_00_40
    create       = 0x00_04_00_00

type Mode = distinct posix.Mode
converter degrade_mode(mode: Mode): auto = posix.Mode(mode)

type MDB_env {.importc, pure, final, incompletestruct.} = object
type MDB_txn {.importc, pure, final, incompletestruct.} = object
type MDB_dbi {.importc, pure.} = distinct cuint
type Error = distinct cint
converter is_error(err: Error): bool = err.cint != 0

#--------------------------------------------------------------------------
# Nim types

type Environment* = ptr MDB_env
type Transaction* = ptr MDB_txn
type Database* = MDB_dbi

type Version* = tuple[major, minor, patch: int; str: string]
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

proc mdb_txn_begin(env: Environment, parent: Transaction, flags: cuint, txn: var Transaction): Error
    {.importc, header: LMDB.}
proc mdb_txn_commit(txn: Transaction): Error
    {.importc, header: LMDB.}
proc mdb_txn_abort(txn: Transaction)
    {.importc, header: LMDB.}

proc mdb_dbi_open(txn: Transaction, name: cstring, flags: cuint, db: var Database): Error
    {.importc, header: LMDB.}

#--------------------------------------------------------------------------
# utils

proc check(err: Error) {.raises: [Database_error].} =
    if err: raise Database_error.new_exception($mdb_strerror(err))

template convert_with_nil[T](src_in: typed): T =
    let src = src_in
    if is_nil(src): T(nil) else: T(src)

#--------------------------------------------------------------------------
# system

proc version*(): Version =
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
    mdb_txn_begin(env, parent, flags, result).check

proc begin*(env: Environment, read_only = false, parent: Transaction = nil): Transaction =
    var flags = {}.Transaction_flags_set
    if read_only: flags.incl Transaction_flags.rd_only
    begin(env, flags, parent)

proc commit*(txn: Transaction) = mdb_txn_commit(txn).check
proc abort*(txn: Transaction) = mdb_txn_abort(txn)

template transaction_scope_guard(txn, body: untyped): untyped =
    when debug: echo "[TXN] ", "began".align(8), " ", txn

    var failed = false
    try:
        body
    except:
        failed = true
        raise
    finally:
        if failed:
            abort(txn)
            when debug: echo "[TXN] ", "aborted".align(8), " ", txn
        else:
            commit(txn)
            when debug: echo "[TXN] ", "commited".align(8), " ", txn

template transaction*(env: Environment; txn, body: untyped): untyped =
    let txn = begin(env)
    transaction_scope_guard(txn, body)

#--------------------------------------------------------------------------
# database

proc open*(txn: Transaction, name: string, flags: Database_flags_set): Database =
    let cname = convert_with_nil[cstring](name)
    mdb_dbi_open(txn, cname, flags, result).check

proc open*(txn: Transaction): Database =
    open(txn, nil, {})

#--------------------------------------------------------------------------
# example

when is_main_module:
    echo "[DB] version ", version()

    let db = open "./test"
    echo "[DB] opened ", db
    echo()

    try:
        transaction db, txn:
            let i = txn.open
            echo "dbi = ", i.int
            raise new_exception(Exception, "should have aborted")
    except:
        echo get_current_exception_msg()
    echo()

    block TEST:
        transaction db, txn:
            let i = txn.open
            echo "should commit, dbi = ", i.int
            break TEST
    echo()

    db.close
    echo "[DB] closed ", db
    echo()
    echo GC_get_statistics()

