/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/-- Every shipped package in this repository, this one and each subdirectory's apart from `test`,
carries the same version, and all are bumped together whether or not each one changed. They are
required separately but resolved into a single application, so one number is what says which
combination of them an application is holding. A new package starts at the current version and
points back here with the same comment the others carry. -/
package middleware where
  version := v!"0.17.1"

/-- `routing` alone and never an engine package, so that an application resolves only the server
it serves on. -/
require routing from git "https://github.com/paulbutcher/lean-routing" @ "v0.15.0"

@[default_target]
lean_lib Middleware

/-- The suite lives in the `test` package, which is where the dependency on `Plausible` lives
too, and the middleware run on LeanIn live in `test/leanin`, which is where LeanIn and the libuv it
links live. Running both from here keeps `lake test` at the repo root as the single entry point,
and runs `scripts/check-runtime.sh` so that a plain `import Lean` cannot reach consumers
unnoticed. -/
@[test_driver]
script tests (args) do
  let env := #[("LEAN_PATH", none), ("LEAN_SRC_PATH", none), ("LAKE", none), ("LAKE_HOME", none),
    ("LAKE_PKG_URL_MAP", none), ("ELAN_TOOLCHAIN", none)]
  let lake ← IO.appPath
  let suite ← IO.Process.spawn
    { cmd := lake.toString, args := #["test"] ++ args.toArray, cwd := some "test", env }
  let status ← suite.wait
  if status != 0 then return status
  let leanin ← IO.Process.spawn
    { cmd := lake.toString, args := #["test"], cwd := some ("test" / "leanin"), env }
  let status ← leanin.wait
  if status != 0 then return status
  let check ← IO.Process.spawn
    { cmd := (__dir__ / "scripts" / "check-runtime.sh").toString, cwd := some __dir__, env }
  check.wait
