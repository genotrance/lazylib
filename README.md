Lazy loading of shared libraries for Nim

There's three ways to use shared libraries with Nim:
1. Link using `-lname` - library needs to be present at compile time for build to succeed and runtime for app to start
2. Link using `{.dynlib.}` - library doesn't need to be present at compile time but is loaded at runtime by Nim before main app is executed
3. Dynamically load at runtime using the `dynlib` module - library doesn't need to be present at compile time and can be loaded by the app when required with the ability to handle errors if the library is not present or specific symbols are missing.

The lazylib method extends #3 by automating the loading and error handling of the library and symbols, allowing the developer to focus on the app.

In combination with tools like [nimterop](https://github.com/nimterop/nimterop) and [c2nim](https://github.com/nim-lang/c2nim), the automated wrapper generation can provide lazy loading with error handling for free.

# Usage

Module documentation can be found [here](https://genotrance.github.io/lazylib/lazylib.html).

 Simply use `{.lazylib.}` in place of `{.dynlib.}` in wrappers and it should work. Specify calling convention like `{.cdecl.}` per usual as well as `{.importc.}` if there's a need to modify or shorten the C name.

```nim
import lazylib

const
  lib = "libz.so"

proc Version*(): cstring {.lazylib: lib, cdecl, importc: "zlib$1".}

if Version.isLoaded():
  echo Version()
else:
  echo "Zlib Version() unavailable, workaround"
```

# Limitations

- `{.push.}` is not supported either for `{.lazylib.}` or for calling convention or `{.importc.}`.
- The `{.pragma.}` shortcut does not work either - each `proc` will need all pragmas specified explicitly.