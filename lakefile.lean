/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL System

/-- Where the hand-written C++ FFI shims live. -/
def cDir : FilePath := __dir__ / "c"

package middleware where
  version := v!"0.1.0"
  testDriver := "tests"
  -- `libcrypto` for `Middleware.Crypto.AesGcm`'s OpenSSL FFI.
  moreLinkArgs := #["-lcrypto"]

require plausible from git
  "https://github.com/leanprover-community/plausible" @ "v4.33.0"

/-- Compiles `c/aesgcm.cpp` against the Lean toolchain's bundled `clang` directly (not the
`leanc` wrapper -- confirmed empirically that `leanc` fails to find `<cstddef>` for a genuine
C++ source file, even given the same flags that make raw `clang` succeed; `leanc` is tuned for
compiling Lean's own *generated* C, not arbitrary C++). Needs two extra hints raw `clang` also
needs here: its bundled libc++-adjacent headers live under `include/clang` rather than the usual
clang resource-dir layout, and it doesn't default to `libstdc++` even though that's what's
installed on this system. -/
target aesGcmO pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "aesgcm.o"
  let srcJob ← inputTextFile (cDir / "aesgcm.cpp")
  let install ← getLeanInstall
  let weakArgs := #[
    "-I", install.includeDir.toString,
    "-I", (install.sysroot / "include" / "clang").toString,
    "-stdlib=libstdc++", "-fPIC"]
  buildO oFile srcJob weakArgs #[] (install.sysroot / "bin" / "clang")

extern_lib libaesgcm pkg := do
  let job ← aesGcmO.fetch
  buildStaticLib (pkg.buildDir / "lib" / nameToStaticLib "aesgcm") #[job]

@[default_target]
lean_lib Middleware

lean_lib Tests

lean_exe tests where
  root := `Main
