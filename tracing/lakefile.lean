/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/--
`serverSpan` is the only middleware needing anything beyond `Std.Http.Server`, and Lake resolves
`require` package-wide: `telemetry` declared in `middleware` would put `telemetry` and its own
`leancurl` requirement into the manifest of every application using any middleware at all.
Keeping it here is what makes tracing opt-in.
-/
package «middleware-tracing» where
  version := v!"0.8.0"

require middleware from ".."

require telemetry from git "https://github.com/paulbutcher/lean-telemetry" @ "v0.4.0"

/-- The module root is `MiddlewareTracing` rather than `Middleware.Tracing` because Lake resolves
a module name to exactly one package, and the `Middleware.*` tree already belongs to `middleware`.
The Lean namespace is unaffected: this still defines `Middleware.serverSpan`. -/
@[default_target]
lean_lib MiddlewareTracing
