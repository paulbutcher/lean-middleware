/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lake DSL

/--
`CookieStore` is the only part of this library that needs OpenSSL, and it needs it through
`lean-libcrypto`. Requiring that here rather than from `middleware` is what lets an application
which doesn't want encrypted cookie sessions build without OpenSSL at all: Lake builds the modules
an application imports, not the packages it resolves.
-/
package «middleware-cookiestore» where
  -- Kept in step with `middleware`; see the note in the root lakefile.
  version := v!"0.19.0"

require middleware from ".."

require «lean-libcrypto» from git
  "https://github.com/paulbutcher/lean-libcrypto" @ "v0.2.1"

require leancrypto from git
  "https://github.com/paulbutcher/leancrypto" @ "v0.4.2"

/-- The module root is `MiddlewareCookieStore` rather than `Middleware.CookieStore` because Lake
resolves a module name to exactly one package, and the `Middleware.*` tree already belongs to
`middleware`. The Lean namespaces are unaffected: this still defines `Middleware.CookieStore` and
`Middleware.Crypto`. -/
@[default_target]
lean_lib MiddlewareCookieStore
