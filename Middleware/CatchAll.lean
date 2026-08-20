/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core

public section

open Std.Http
open Std.Http.Server
open Std.Async

namespace Middleware

/--
Wraps a handler so that any `IO.Error` thrown while producing a response is caught and turned
into a `500 Internal Server Error` response instead of tearing down the connection. `onError`
runs first, for logging or metrics; it defaults to doing nothing.
-/
def catchAll (onError : IO.Error → Async Unit := fun _ => pure ()) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        try
          handler.onRequest req
        catch e =>
          onError e
          Response.internalServerError.text "Internal Server Error" }

end Middleware
