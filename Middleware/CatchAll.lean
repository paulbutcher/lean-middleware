/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core

public section
open Std.Http
open Routing

namespace Middleware

/--
Wraps a handler so that any `IO.Error` thrown while producing a response is caught and turned
into a `500 Internal Server Error` response instead of tearing down the connection. The error is
reported to the wrapped handler's `onFailure`, which is the callback the server itself invokes for
transport errors, so an application has one place to put error logging rather than two. The
recovered error and a fatal transport error arrive there indistinguishable from each other, since
an `IO.Error` is all either carries.

What reaches it differs by engine. On `.std` a connection failing mid-request raises here like any
other error. LeanIn ends such a request without raising anything a handler can catch, and reports
it to `onFailure` itself.

Attach that callback to the handler `Middleware.apply` is *given*, not to the stack it returns:

```
Middleware.apply [..., catchAll, ...] { base with onFailure := log }
```

Middleware composes inwards, so `catchAll` reports to the `onFailure` of whatever sits below it,
which propagates up from `base`. Setting `onFailure` on an already-assembled stack sets the
field on the outermost handler alone, where `catchAll` cannot reach it, and every error it
recovers from goes unreported.
-/
@[expose] def catchAll {e : Engine} [ServerEngine e] : Middleware e :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        try
          handler.onRequest req
        catch err =>
          handler.onFailure err
          e.text Response.internalServerError "Internal Server Error" }

end Middleware
