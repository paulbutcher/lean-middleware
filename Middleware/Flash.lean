/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Session

open Std.Http
open Std.Http.Server

namespace Middleware

private def flashKey : String := "__flash"

/-- The flash message left by the *previous* request, if any (one-request lifetime). -/
structure Flash where
  message : Option String := none
deriving TypeName

/-- A flash message for the handler to persist for the *next* request only. -/
structure FlashMessage where
  value : String
deriving TypeName

/-- Reads and strips the reserved `__flash` key out of the session (requires `session` wrapped
outer; degrades to an absent message rather than crashing if it isn't), exposing it as `Flash`.
On the way out, a `FlashMessage` the handler attaches is folded into whatever `SessionUpdate` is
already on the response (or, if none, the flash-stripped session read on the way in), so
`session` persists both in one write. A response that sets no `FlashMessage` passes through
unchanged.

There's a subtlety worth calling out: stripping `__flash`
only affects what *this* request and its response see, not the backing store. If a request reads
a flash message but its response never touches `SessionUpdate` at all (no new flash, no other
session write), nothing gets persisted, so the old flash message is still sitting in the stored
session and will be delivered again on the *next* request too, and the one after that, until some
request's response actually performs a session write. A handler that wants "delivered exactly
once" needs to persist the (already-stripped) `SessionData` it received, e.g. via
`SessionUpdate.write sessionData.data`, even when it has nothing else to change. -/
def flash : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let sessionData := (req.extensions.get SessionData).getD {}
        let message := sessionData.data.get flashKey
        let stripped := sessionData.data.remove flashKey
        let extensions := req.extensions.insert ({ sessionData with data := stripped } : SessionData)
        let extensions := extensions.insert ({ message } : Flash)
        let req := { req with extensions }
        let resp ← handler.onRequest req
        match resp.extensions.get FlashMessage with
        | none => pure resp
        | some fm =>
          let baseData := match resp.extensions.get SessionUpdate with
            | some (.write d) => d
            | _ => stripped
          let newData := (baseData.remove flashKey).set flashKey fm.value
          pure { resp with extensions := resp.extensions.insert (SessionUpdate.write newData) } }

end Middleware
