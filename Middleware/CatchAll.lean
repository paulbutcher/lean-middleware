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
into a `500 Internal Server Error` response instead of tearing down the connection. The error is
reported to the wrapped handler's `onFailure`, which is the callback `Std.Http.Server` itself
invokes for transport errors, so an application has one place to put error logging rather than
two. The recovered error and a fatal transport error arrive there indistinguishable from each
other, since an `IO.Error` is all either carries.

Attach that callback to the handler `Middleware.apply` is *given*, not to the stack it returns:

```
Middleware.apply [..., catchAll, ...] (base.withFailure log)
```

Middleware composes inwards, so `catchAll` reports to the `onFailure` of whatever sits below it,
which propagates up from `base`. Calling `withFailure` on an already-assembled stack sets the
field on the outermost handler alone, where `catchAll` cannot reach it, and every error it
recovers from goes unreported.
-/
@[expose] def catchAll : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        try
          handler.onRequest req
        catch e =>
          handler.onFailure e
          Response.internalServerError.text "Internal Server Error" }

end Middleware
