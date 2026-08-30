/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/-- All three packages carry the same version and are bumped together, whether or not each one
changed. They are required separately but resolved into a single application, so one number is
what says which combination of them an application is holding. -/
package middleware where
  version := v!"0.13.0"

@[default_target]
lean_lib Middleware

/-- The suite lives in the `test` package, which is where the dependency on `Plausible` lives
too. Running it from here keeps `lake test` at the repo root as the single entry point. -/
@[test_driver]
script tests (args) do
  let lake ← IO.appPath
  let suite ← IO.Process.spawn {
    cmd := lake.toString
    args := #["test"] ++ args.toArray
    cwd := some "test"
    env := #[("LEAN_PATH", none), ("LEAN_SRC_PATH", none), ("LAKE", none), ("LAKE_HOME", none),
      ("LAKE_PKG_URL_MAP", none), ("ELAN_TOOLCHAIN", none)]
  }
  suite.wait
