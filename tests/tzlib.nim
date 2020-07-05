import lazylib

const
  lib = "libz.so"

proc zlibVersion*(): cstring {.lazylib: "libz.so", cdecl.}

proc Version*(): cstring {.lazylib: lib, cdecl, importc: "zlib$1".}

proc Random*(): cstring {.lazylib: lib, cdecl, importc: "zlib$1".}

echo zlibVersion()
echo Version()

try:
  echo Random()
except LazySymbolNotFound:
  echo "Caught it"