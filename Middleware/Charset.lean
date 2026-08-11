/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Core

open Std.Http
open Std.Http.Server

namespace Middleware.Charset

/-- Whether a `Content-Type` value is text-based enough to need a charset, mirroring Ring's own
plain substring checks (not a full media-type grammar) -- `text/*` or `application/xml`. -/
def isTextBased (contentType : String) : Bool :=
  let ct := contentType.toLower
  ct.startsWith "text/" || (ct.splitOn "application/xml").length > 1

/-- Whether a `Content-Type` value already declares a `charset` parameter. -/
def hasCharset (contentType : String) : Bool :=
  (contentType.splitOn ";").any fun part => part.trimAscii.toString.toLower.startsWith "charset="

end Middleware.Charset

namespace Middleware

/-- Appends `; charset={charset}` to the response's `Content-Type` when it's text-based
(`Middleware.Charset.isTextBased`) and doesn't already declare one. No-op if there's no
`Content-Type` at all -- run this after `contentType` (or anything else that sets one) for it to
have anything to act on. -/
def defaultCharset (charset : String := "utf-8") : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        match resp.line.headers.get? Header.Name.contentType with
        | none => pure resp
        | some v =>
          if Charset.isTextBased v.value && !Charset.hasCharset v.value then
            let newValue := Header.Value.ofString! s!"{v.value}; charset={charset}"
            let headers := (resp.line.headers.erase Header.Name.contentType).insert
              Header.Name.contentType newValue
            pure { resp with line := { resp.line with headers } }
          else
            pure resp }

end Middleware
