/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL System

package middleware where
  version := v!"0.2.0"

require plausible from git
  "https://github.com/leanprover-community/plausible" @ "v4.33.0"

@[default_target]
lean_lib Middleware

lean_lib Tests

lean_exe tests where
  root := `Main

/-- Runs this package's own suite and then the `cookiestore` package's, so `lake test` from the
repo root still covers everything despite the two being separate packages (see `cookiestore`'s
own lakefile for why they are). -/
@[test_driver]
script «test-all» (args) do
  let lake ← IO.appPath
  let root ← IO.Process.spawn { cmd := lake.toString, args := #["exe", "tests"] ++ args.toArray }
  let code ← root.wait
  if code != 0 then
    return code
  let cookieStore ← IO.Process.spawn {
    cmd := lake.toString
    args := #["test"] ++ args.toArray
    cwd := some "cookiestore"
    env := #[("LEAN_PATH", none), ("LEAN_SRC_PATH", none), ("LAKE", none), ("LAKE_HOME", none),
      ("LAKE_PKG_URL_MAP", none), ("ELAN_TOOLCHAIN", none)]
  }
  cookieStore.wait
