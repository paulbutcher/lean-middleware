/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL System

/-- Where the hand-written C FFI shims live. -/
def cDir : FilePath := __dir__ / "c"

package middleware where
  version := v!"0.2.0"
  testDriver := "tests"
  -- `libcrypto` for `Middleware.Crypto.AesGcm`'s OpenSSL FFI.
  moreLinkArgs := #["-lcrypto"]

require plausible from git
  "https://github.com/leanprover-community/plausible" @ "v4.33.0"

/-- Compiles `c/aesgcm.c` against the Lean toolchain's bundled `clang` directly rather than
through `leanc`/`buildLeanO`: those wire up `-nostdinc --sysroot <lean sysroot>`, which is right
for Lean's own self-contained generated C but would also hide the system's `<openssl/*>` headers
this shim needs. Needs one extra hint raw `clang` also needs here: its bundled compiler-builtin
headers (`<stdbool.h>` etc.) live under `include/clang` rather than the usual clang resource-dir
layout. On macOS this `clang` additionally needs an explicit SDK sysroot to find *any* system
header at all (`<stdlib.h>` included); unlike Apple's own `clang` wrapper it won't discover one
on its own, so it's obtained by hand via `xcrun`. -/
target aesGcmO pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "aesgcm.o"
  let srcJob ← inputTextFile (cDir / "aesgcm.c")
  let install ← getLeanInstall
  let sysrootArgs ← if Platform.isOSX then do
    let sdk ← IO.Process.output { cmd := "xcrun", args := #["--sdk", "macosx", "--show-sdk-path"] }
    pure #["-isysroot", sdk.stdout.trimAscii.toString]
  else
    pure #[]
  let weakArgs := #[
    "-I", install.includeDir.toString,
    "-I", (install.sysroot / "include" / "clang").toString] ++ sysrootArgs ++ #["-fPIC"]
  buildO oFile srcJob weakArgs #[] (install.sysroot / "bin" / "clang")

extern_lib libaesgcm pkg := do
  let job ← aesGcmO.fetch
  buildStaticLib (pkg.buildDir / "lib" / nameToStaticLib "aesgcm") #[job]

@[default_target]
lean_lib Middleware

lean_lib Tests

lean_exe tests where
  root := `Main
