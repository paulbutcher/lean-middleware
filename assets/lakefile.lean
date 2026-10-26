/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/--
Fingerprinting needs SHA-256, which `leancrypto` has. Requiring it here rather than from
`middleware` keeps it out of the manifest of every application that serves no assets: Lake
resolves `require` package-wide.
-/
package «middleware-assets» where
  -- Kept in step with `middleware`; see the note in the root lakefile.
  version := v!"0.19.1"

require middleware from ".."

require leancrypto from git
  "https://github.com/paulbutcher/leancrypto" @ "v0.4.2"

/-- The module root is `MiddlewareAssets` rather than `Middleware.Assets` because Lake resolves a
module name to exactly one package, and the `Middleware.*` tree already belongs to `middleware`.
The Lean namespaces are unaffected: this still defines `Middleware.Assets` and `Middleware.assets`. -/
@[default_target]
lean_lib MiddlewareAssets
