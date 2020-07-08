import lazylib

when defined(windows):
  const libz = "zlib1.dll"
elif defined(macosx):
  const libz = "libz.dylib"
else:
  const libz = "libz.so.1"

proc zlibVersion*(): cstring {.lazylib: libz, cdecl, importc.}

proc Version*(): cstring {.lazylib: "libz.so(|.1)", cdecl, importc: "zlib$1".}

proc Random*(): cstring {.lazylib: libz, cdecl, importc: "zlib$1".}

try:
  echo zlibVersion()
  echo Version()
  echo Random()
except LazyLibNotFound:
  echo "No zlib found"
except LazySymNotFound:
  echo "Random() should fail"

if zlibVersion.isLoaded():
  echo "Cool"

doAssert not Random.isLoaded()