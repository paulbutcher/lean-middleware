/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/--
The middleware run on LeanIn. A package of its own rather than part of `test`, because requiring
LeanIn links its C shim, and the libuv it wraps, into every executable of the requiring package,
`test`'s `leanFree` included.
-/
package «middleware-leanin-tests» where
  testDriver := "tests"

require middleware from "../.."

require «routing-leanin» from git
  "https://github.com/paulbutcher/lean-routing" @ "v0.15.2" / "leanin"

@[default_target]
lean_lib LeanInTests

lean_exe tests where
  root := `Main
