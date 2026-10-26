/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/--
The test suite is its own package so that neither `middleware` nor `middleware-cookiestore` has
to declare a dependency on `Plausible`: Lake resolves a package's requirements transitively, so
anything a shipping package requires is fetched and built by every application that uses it.
-/
package «middleware-tests» where
  testDriver := "tests"

require middleware from ".."

require «middleware-cookiestore» from "../cookiestore"

require «middleware-tracing» from "../tracing"

require «middleware-assets» from "../assets"

require «routing-std» from git
  "https://github.com/paulbutcher/lean-routing" @ "v0.15.2" / "std"

require plausible from git
  "https://github.com/leanprover-community/plausible" @ "v4.34.0"

@[default_target]
lean_lib Tests

lean_exe tests where
  root := `Main

/-- The subject of `scripts/check-runtime.sh` rather than a test, so not a default target. -/
lean_exe leanFree where
  root := `LeanFree
