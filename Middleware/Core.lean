/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Server

open Std.Http
open Std.Http.Server

/--
A function that wraps a `StatelessHandler`, adding behavior before and/or after the wrapped
handler runs. Composes via ordinary function composition.
-/
abbrev Middleware := StatelessHandler → StatelessHandler

namespace Middleware

/-- Leaves the handler unchanged. -/
def id : Middleware := fun handler => handler

/--
Applies a stack of middleware to a base handler. The first element of `mws` becomes the
outermost layer, closest to the client; the last element sits closest to `base`. A request
passes through the list head-first; the response flows back tail-first.
-/
def apply (mws : List Middleware) (base : StatelessHandler) : StatelessHandler :=
  mws.foldr (fun mw acc => mw acc) base

end Middleware
