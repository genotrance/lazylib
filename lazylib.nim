import dynlib, macros, strutils, tables
export dynlib, strutils, tables

type
  Lazylibs = object
    libHandle*: TableRef[string, LibHandle]

  LazyException = CatchableError

  LazyLibNotFound* = LazyException

  LazySymbolNotFound* = LazyException

var
  lazyLibs* = new(Lazylibs)
lazyLibs.libHandle = newTable[string, LibHandle]()

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

macro lazylib*(name, procDef: untyped): untyped =
  # Basic checks
  doAssert procDef.kind == nnkProcDef, "\n{.lazylib.} is to be used with procs"

  # Load the library at runtime
  result = newNimNode(nnkStmtList)
  result.add quote do:
    doAssert `name`.len != 0, "\n{.lazylib.} library name/path expected"
    if not lazyLibs.libHandle.hasKey(`name`):
      # Only one time
      let
        handle = loadLibPattern(`name`)
      if handle.isNil:
        raise newException(LazyLibNotFound, "Could not load " & `name`)
      lazyLibs.libHandle[`name`] = handle

  # Get proc details
  let
    (procName, procImpC, procConv, impIdx, convIdx) = procDef.getProcInfo()
    procImpl = newNimNode(nnkStmtList)
    libIdent = newIdentNode("lib")
    symIdent = newIdentNode("sym")

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

  # Add implementation to load proc and call
  procImpl.add quote do:
    if not lazyLibs.libHandle.hasKey(`name`):
      raise newException(LazyLibNotFound, `name` & "is not loaded")

    let
      `libIdent` = lazyLibs.libHandle[`name`]
      `symIdent` = `libIdent`.symAddr(`symName`)
    if `symIdent`.isNil:
      raise newException(LazySymbolNotFound, "Could not load symbol `" & `symName` & "()`")

  # Proc signature - not able to add {.convention.} pragma via `quote do:`
  let
    # symCall = cast[signature](sym)
    signature = "proc " & (block:
      if procDef.len > 3 and procDef[3].kind == nnkFormalParams:
        $procDef[3].repr
      else:
        "()"
    ) & " {." & convention & ".}"

    # symCall(params)
    paramTypes =
      if procDef.len > 3 and procDef[3].kind == nnkFormalParams and procDef[3].len > 1:
        ($procDef[3][1 .. ^1].repr).strip(chars = {'[', ']'})
      else:
        ""

  # Strip out param types
  var
    params: seq[string]
  if paramTypes.len != 0:
    for param in paramTypes.split(seps = {';', ','}):
      params.add param.split(':')[0]

  # Cast sym to symCall and invoke with params
  procImpl.add parseStmt("""let
  symCall = cast[$1](sym)
symCall($2)""" % [signature, params.join(", ")]
  )

  # Add implementation to definition
  procDef[^1] = procImpl

  # Remove {.importc.} and {.convention.}
  if procDef.len > 4:
    if impIdx != -1 or convIdx != -1:
      # Remove backwards
      for i in countdown(procDef[4].len-1, 0):
        if i in [impIdx, convIdx]:
          procDef[4].del(i)

      # If no pragmas left, remove
      if procDef[4].len == 0:
        procDef[4] = newNimNode(nnkEmpty)

  result.add procDef
