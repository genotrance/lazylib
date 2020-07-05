import lazylib

when defined(windows):
  const libz = "zlib1.dll"
elif defined(macosx):
  const libz = "libz.dylib"
else:
  const libz = "libz.so.1"

proc zlibVersion*(): cstring {.lazylib: libz, cdecl.}

proc Version*(): cstring {.lazylib: libz, cdecl, importc: "zlib$1".}

proc Random*(): cstring {.lazylib: libz, cdecl, importc: "zlib$1".}

echo zlibVersion()
echo Version()

try:
  echo Random()
except LazySymbolNotFound:
  echo "Caught it"