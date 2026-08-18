/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL System

/-- Where the hand-written C FFI shim lives. -/
def cDir : FilePath := __dir__ / "c"

/-- Homebrew's OpenSSL formula is keg-only on macOS (it's deliberately not linked into
`/usr/local` or `/opt/homebrew`, since it would shadow the system's own headerless, ABI-incompatible
libcrypto), so its install prefix must be looked up explicitly rather than assumed to be on the
default search path. Tries the current formula name before the legacy one. -/
def opensslPrefix : IO String := do
  for formula in #["openssl@3", "openssl"] do
    let out ← IO.Process.output { cmd := "brew", args := #["--prefix", formula] }
    if out.exitCode == 0 then
      return out.stdout.trimAscii.toString
  throw <| IO.userError "could not find a Homebrew OpenSSL install (tried openssl@3, openssl)"

/--
`CookieStore` is the only part of this library that isn't pure Lean, and `moreLinkArgs` and
`extern_lib` are both package-scoped: Lake applies them to every executable linked against the
package that declares them, with no regard for which modules were actually imported. Keeping
them here rather than in `middleware` is therefore the only way an application that doesn't want
encrypted cookie sessions can avoid needing OpenSSL to build at all.
-/
package «middleware-cookiestore» where
  version := v!"0.4.0"
  -- `libcrypto` for `Middleware.Crypto.AesGcm`'s OpenSSL FFI.
  moreLinkArgs := #["-lcrypto"] ++ run_io do
    if Platform.isOSX then
      return #["-L", s!"{← opensslPrefix}/lib"]
    else
      return #[]

require middleware from ".."

/-- Compiles `c/aesgcm.c` against the Lean toolchain's bundled `clang` directly rather than
through `leanc`/`buildLeanO`: those wire up `-nostdinc --sysroot <lean sysroot>`, which is right
for Lean's own self-contained generated C but would also hide the system's `<openssl/*>` headers
this shim needs. Needs a few extra hints raw `clang` also needs here: its bundled compiler-builtin
headers (`<stdbool.h>` etc.) live under `include/clang` rather than the usual clang resource-dir
layout. On macOS this `clang` additionally needs an explicit SDK sysroot to find *any* system
header at all (`<stdlib.h>` included); unlike Apple's own `clang` wrapper it won't discover one
on its own, so it's obtained by hand via `xcrun`. macOS also needs Homebrew's keg-only OpenSSL
headers pointed to explicitly, matching the linker path added for it in `moreLinkArgs`. -/
target aesGcmO pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "aesgcm.o"
  let srcJob ← inputTextFile (cDir / "aesgcm.c")
  let install ← getLeanInstall
  let macArgs ← if Platform.isOSX then do
    let sdk ← IO.Process.output { cmd := "xcrun", args := #["--sdk", "macosx", "--show-sdk-path"] }
    let openssl ← opensslPrefix
    pure #["-isysroot", sdk.stdout.trimAscii.toString, "-I", s!"{openssl}/include"]
  else
    pure #[]
  let weakArgs := #[
    "-I", install.includeDir.toString,
    "-I", (install.sysroot / "include" / "clang").toString] ++ macArgs ++ #["-fPIC"]
  buildO oFile srcJob weakArgs #[] (install.sysroot / "bin" / "clang")

extern_lib libaesgcm pkg := do
  let job ← aesGcmO.fetch
  buildStaticLib (pkg.buildDir / "lib" / nameToStaticLib "aesgcm") #[job]

/-- The module root is `MiddlewareCookieStore` rather than `Middleware.CookieStore` because Lake
resolves a module name to exactly one package, and the `Middleware.*` tree already belongs to
`middleware`. The Lean namespaces are unaffected: this still defines `Middleware.CookieStore` and
`Middleware.Crypto`. -/
@[default_target]
lean_lib MiddlewareCookieStore
