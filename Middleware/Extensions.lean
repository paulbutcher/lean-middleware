/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core

public section

open Std.Async
open Std.Http
open Std.Http.Server

namespace Middleware

/-- A handler that is handed the request extension it needs, rather than reading it itself. -/
abbrev ExtensionHandler (α : Type) :=
  α → Request Body.Stream → ContextAsync (Response Body.Any)

/-- Answers a request that reached a handler without an extension the stack was supposed to
establish. `500`, because the request is fine and the server is not. -/
def defaultMissingExtension : StatelessHandler :=
  { onRequest := fun _ =>
      Response.internalServerError.text "a required request extension was not established" }

/--
Hands a handler an extension rather than leaving it to ask for one, so that a stack assembled
without the middleware that establishes `α` refuses the request instead of running the handler
against a value that reads as absent.

The `Option` that `Extensions.get` returns carries two facts at once: that the middleware ran and
found nothing (an empty form, no cookie of that name, no flash message), and that the middleware
was never in the stack at all. The first is an ordinary request; the second is a misconfigured
server, and a handler that answers both the same way answers it silently. `missing` separates
them.

This is a handler combinator, not a `Middleware`: it wraps the innermost thing, and has no place
in `apply`'s list.

`Extract.required` is the extractor form, and `Extract.params`, `Extract.session` and the rest are
its specialisations.

Reading an extension directly still compiles, and remains the right answer where a refusal costs
more than a degraded response: code reached from outside any handler, such as a redirect that any
route can take, has no combinator to sit inside and may prefer to carry on without the value.
-/
def requiring {α : Type} [TypeName α] (handler : ExtensionHandler α)
    (missing : StatelessHandler := defaultMissingExtension) :
    Request Body.Stream → ContextAsync (Response Body.Any) := fun req =>
  match req.extensions.get α with
  | some value => handler value req
  | none => missing.onRequest req

end Middleware
