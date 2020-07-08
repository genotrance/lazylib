import dynlib, macros, strutils, tables

type
  # Sym name to pointer
  SymTable = Table[string, pointer]

  # Nim proc pointer to libName and symName
  ProcInfo = object
    libName: string
    symName: string

  # Global to cache all loaded library handles and symbol pointers
  LazyLibs = object
    # Lib name to handle
    libHandle: Table[string, LibHandle]

    # Lib name to sym table
    symTable: Table[string, SymTable]

    # Nim proc to sym name
    procTable: Table[pointer, ProcInfo]

  LazyException* = object of CatchableError

  LazyLibNotFound* = object of LazyException

  LazySymNotFound* = object of LazyException

# Initialize cache on startup
var
  lazyLibs: LazyLibs

# TODO:
# - {.push cdecl, importc, lazylib.} don't work
# - {.pragma lazy, cdecl, importc, lazylib.} doesn't work

proc getProcInfo(node: NimNode):
  tuple[procName, importc, convention: string, impIdx, convIdx: int] =
  # Get name and calling convention of proc when passed nnkProcDef
  #
  # If {.importc.} is specified, return that name else simply
  # return the name of the proc as defined
  #
  # If {.importc.} or convention are specified, return their indexes
  # in `impIdx` and `convIdx` so that they can be deleted later. The
  # values will be used elsewhere and not passed back to caller.
  result.impIdx = -1
  result.convIdx = -1
  if not node.isNil:
    var
      # {.importc: "xyz".} found
      found = false
    for i in 0 ..< node.len:
      case node[i].kind
      of nnkIdent:
        let
          ident = $node[i]
        case node.kind
        of nnkProcDef, nnkPostfix:
          # proc name as defined
          if ident != "*":
            result.procName = ident
        of nnkExprColonExpr:
          # {.importc: "xyz".} pragma name
          if ident == "importc":
            found = true
          else:
            found = false
        of nnkPragma:
          # convention
          if ident in ["nimcall", "closure", "stdcall", "cdecl", "safecall",
            "fastcall", "syscall", "noconv"]:
            result.convention = ident
            result.convIdx = i
          elif ident == "importc":
            # Empty `{.importc.}`
            result.impIdx = i
        else:
          discard
      of nnkStrLit:
        # {.importc: "xyz".} pragma value
        if node.kind == nnkExprColonExpr and found:
          result.importc = $node[i]
      of nnkPostfix, nnkPragma, nnkExprColonExpr:
        # Recurse
        let
          (pname, impc, conv, iidx, cidx) = node[i].getProcInfo()
        if pname.len != 0:
          result.procName = pname
        if impc.len != 0:
          result.importc = impc
          if node.kind == nnkPragma:
            # {.importc.} pragma offset
            result.impIdx = i
        if conv.len != 0:
          result.convention = conv
        if iidx != -1:
          result.impIdx = iidx
        if cidx != -1:
          result.convIdx = cidx
      else:
        discard

proc lazyLoadLib(libName: string) =
  # Load specified library `libName` at runtime - used by `{.lazylib.}`
  #
  # `libName` can be a library name, full path or pattern as supported
  # by `{.dynlib.}`
  #
  # If library is not found, raise `LazyLibNotFound` which can be
  # caught and handled as required by app.
  doAssert libName.len != 0, "\nLibrary name/path/pattern expected for `lazyLoadLib()`"
  if not lazyLibs.libHandle.hasKey(libName):
    # Load library only once
    let
      handle = loadLibPattern(libName)
    if handle.isNil:
      raise newException(LazyLibNotFound, "Could not load `" & libName & "`")
    lazyLibs.libHandle[libName] = handle
    lazyLibs.symTable.add(libName, SymTable())

proc lazySymAddr(libName, symName: string): pointer =
  # Load specified `symName` from library `libName` at runtime - used by
  # `{.lazylib.}`, no need to directly call this proc.
  #
  # `libName` can be a library name, full path or pattern as supported
  # by `{.dynlib.}`. `lazyLoadSym()` will load the lib if not already
  # done with `lazyLoadLib()`.
  #
  # `symName` is the name of the symbol to load.
  #
  # If library is not found, raise `LazyLibNotFound` which can be
  # caught and handled as required by app. If symbol is not found,
  # raise `LazySymNotFound`.
  #
  # Returns pointer to loaded symbol.
  if not lazyLibs.libHandle.hasKey(libName):
    lazyLoadLib(libName)

  doAssert symName.len != 0, "\nSymbol name expected for `lazySymAddr()`"
  if not lazyLibs.symTable[libName].hasKey(symName):
    # Load symbol only once
    let
      lib = lazyLibs.libHandle[libName]
    result = lib.symAddr(symName)
    if result.isNil:
      raise newException(LazySymNotFound, "Could not load symbol `" & symName & "()`")
    lazyLibs.symTable[libName][symName] = result
  else:
    result = lazyLibs.symTable[libName][symName]

proc lazyRegister(libName, symName: string, procPtr: pointer) =
  # Register a proc as lazy to enable `isLoaded()` runtime check
  lazyLibs.procTable.add(procPtr, ProcInfo(libName: libName, symName: symName))

macro lazylib*(libName, procDef: untyped): untyped =
  ## Pragma to load C/C++ libraries and symbols at runtime
  ##
  ## Drop-in substitute for `{.dynlib.}`, difference being that the library
  ## and symbol are loaded on use rather than at app startup. This allows the
  ## developer to handle error conditions like a missing library or symbol
  ## gracefully.
  ##
  ## Raises `LazyLibNotFound` if library is not found and `LazySymNotFound` if
  ## symbol is not found in the loaded library.
  ##
  ## Specify calling convention like `{.cdecl.}` per usual as well as
  ## `{.importc.}` if there's a need to modify or shorten the C name.
  runnableExamples:
    const
      lib = "libz.so"

    proc Version*(): cstring {.lazylib: lib, cdecl, importc: "zlib$1".}

    if Version.isLoaded():
      echo Version()
    else:
      echo "Zlib Version() unavailable, workaround"

  # Basic checks
  doAssert procDef.kind == nnkProcDef, "\n{.lazylib.} is to be used with procs"

  result = newNimNode(nnkStmtList)

  # Get proc details
  let
    procImpl = newNimNode(nnkStmtList)
    (procName, procImpC, procConv, impIdx, convIdx) = procDef.getProcInfo()

    # Final symbol name
    symName =
      if procImpC.len != 0:
        if "$" in procImpC or "#" in procImpC:
          # compile() {.importc: "pcre_$1".}
          procImpC % procName
        else:
          # coolName() {.importc: "cool_name".}
          procImpC
      else:
        # origName()
        procName

    # Calling convention
    convention =
      if procConv.len == 0:
        "closure"
      else:
        procConv

    symIdent = newIdentNode("sym")

  # Add proc implementation to load lib and symbol
  procImpl.add quote do:
    let `symIdent` = lazySymAddr(`libName`, `symName`)

  # Proc signature - not able to add {.convention.} pragma via `quote do:`
  let
    # `cast[signature](sym)`
    #
    # `signature` = `proc (params: types): return {.convention.}`
    signature = "proc " & (block:
      if procDef.len > 3 and procDef[3].kind == nnkFormalParams:
        $procDef[3].repr
      else:
        "()"
    ) & " {." & convention & ".}"

    # Only `(param: types)` portion for calling `sym` once cast
    paramTypes =
      if procDef.len > 3 and procDef[3].kind == nnkFormalParams and procDef[3].len > 1:
        ($procDef[3][1 .. ^1].repr).strip(chars = {'[', ']'})
      else:
        ""

  # Strip out `types` from `(param: types)` - not needed for calling procs
  var
    params: seq[string]
  if paramTypes.len != 0:
    for param in paramTypes.split(seps = {';', ','}):
      params.add param.split(':')[0]

  # Cast `sym` to `signature` and invoke with `params`
  procImpl.add parseStmt("cast[$1](sym)($2)" % [signature, params.join(", ")])

  # Replace any existing proc implementation
  procDef[^1] = procImpl

  # Remove {.importc.} and {.convention.} since Nim does not need to
  # load this proc using FFI
  if procDef.len > 4:
    if impIdx != -1 or convIdx != -1:
      # Remove backwards
      for i in countdown(procDef[4].len-1, 0):
        if i in [impIdx, convIdx]:
          procDef[4].del(i)

      # If no pragmas left, remove
      if procDef[4].len == 0:
        procDef[4] = newNimNode(nnkEmpty)

  # Return updated proc
  result.add procDef

  # Register the symbol for `isLoaded()`
  result.add quote do:
    lazyRegister(`libName`, `symName`, cast[pointer](`procName`))

template isLoaded*(procSym: untyped): untyped =
  ## Check if the specified proc was loaded successfully by lazylib
  ##
  ## This template can be used instead of relying on `LazyLibNotFound`
  ## and `LazySymNotFound` exceptions.
  var
    result = false
    procPtr = cast[pointer](procSym)
  if lazyLibs.procTable.hasKey(procPtr):
    try:
      discard lazySymAddr(
        lazyLibs.procTable[procPtr].libName,
        lazyLibs.procTable[procPtr].symName)
      result = true
    except LazyException:
      discard

  result