/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Session
public import Middleware.Params
public import Middleware.Multipart

public section

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def xCsrfToken : Header.Name := .mk "x-csrf-token"
def xXsrfToken : Header.Name := .mk "x-xsrf-token"

end Middleware.Header.Name

namespace Middleware

private def antiForgeryKey : String := "__anti-forgery-token"

/-- The anti-forgery token established for this request (an existing one from the session, or a
freshly minted one): attached as a request extension for a handler to embed in a form or
response. This codebase has no dynamic-binding mechanism to stash a token in, so an extension is
the substitute, matching how `SessionData`/`Flash` are already delivered. -/
structure AntiForgeryToken where
  value : String
deriving TypeName

/-- Compares two byte strings without leaking their content through a timing side-channel one
byte at a time (`==` on `ByteArray` short-circuits on the first differing byte). Only a *length*
mismatch is allowed to affect timing, the same trade-off standard constant-time compares make
elsewhere (e.g. .NET's `FixedTimeEquals`, Rack's `secure_compare`), since length alone isn't
secret. -/
private def constantTimeEq (a b : ByteArray) : Bool :=
  if a.size != b.size then false
  else
    let diff := (List.range a.size).foldl (init := (0 : UInt8))
      fun acc i => acc ||| (a.get! i ^^^ b.get! i)
    diff == 0

/-- Returns `403` with a plain HTML body; `AntiForgeryOptions.errorHandler`'s default. -/
def defaultAntiForgeryErrorHandler : StatelessHandler :=
  { onRequest := fun _ => Response.forbidden.html "<h1>Invalid anti-forgery token</h1>" }

/-- Options for `antiForgery`. -/
structure AntiForgeryOptions where
  /-- The form/multipart field name a submitted token is read from. -/
  paramName : String := "__anti-forgery-token"
  /-- Called in place of the inner handler when the token is missing or wrong. -/
  errorHandler : StatelessHandler := defaultAntiForgeryErrorHandler
  /-- If set, a request carrying this header (present and non-blank) is treated as safe without
  needing a valid token at all -- e.g. same-origin fetch/XHR code that already sets a custom
  header, something a cross-origin attacker's form or script can't forge under the browser's
  CORS rules. Off (`none`) by default. -/
  safeHeader : Option Header.Name := none

private def isSafeMethod (method : Method) : Bool :=
  method == .get || method == .head || method == .options

/-- Reads a submitted token from (in order): the form-urlencoded `Params` field, a `.bytes`-backed
`MultipartParams` field (a `.tempFile`-backed one can't sensibly hold a form token), the
`X-CSRF-Token` header, then the `X-XSRF-Token` header. -/
private def requestToken (req : Request Body.Stream) (paramName : String) : Option String :=
  ((req.extensions.get Params).bind (·.form.get paramName))
  |>.orElse (fun _ => (req.extensions.get MultipartParams).bind (·.get paramName)
    |>.bind (fun part => match part.content with
      | .bytes data => some (String.fromUTF8! data)
      | .tempFile .. => none))
  |>.orElse (fun _ => req.line.headers.get? Header.Name.xCsrfToken |>.map (·.value.trimAscii.toString))
  |>.orElse (fun _ => req.line.headers.get? Header.Name.xXsrfToken |>.map (·.value.trimAscii.toString))

/-- Prevents CSRF attacks: any non-safe request (anything but `GET`/`HEAD`/`OPTIONS`) must carry a
token matching the one established for its session, or `options.errorHandler` runs in place of the
inner handler. The token is delivered to a validated request via the `AntiForgeryToken` extension.

Layered directly on `SessionData`/`SessionUpdate`, the same way `flash` is -- not behind a second
pluggable strategy abstraction, since this codebase's session storage is already pluggable via
`SessionStore` and a second layer on top of it isn't earning its keep for a single, obvious
strategy. Requires `session` wrapped outer to have anything to check against; if
it isn't, every non-safe request fails validation (no stored token can ever be produced to match
against), i.e. this middleware **fails closed** without `session` -- the opposite default from
every other middleware's graceful degradation, and deliberately so here. -/
def antiForgery (options : AntiForgeryOptions := {}) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let sessionData := (req.extensions.get SessionData).getD {}
        let storedToken := sessionData.data.get antiForgeryKey
        let hasSafeHeader := match options.safeHeader with
          | none => false
          | some name => match req.line.headers.get? name with
            | some v => !v.value.trimAscii.toString.isEmpty
            | none => false
        let valid :=
          isSafeMethod req.line.method || hasSafeHeader ||
          match requestToken req options.paramName, storedToken with
          | some sent, some stored => constantTimeEq sent.toUTF8 stored.toUTF8
          | _, _ => false
        if !valid then
          options.errorHandler.onRequest req
        else do
          let token ← match storedToken with
            | some t => pure t
            | none => genSessionId
          let req := { req with extensions := req.extensions.insert ({ value := token } : AntiForgeryToken) }
          let resp ← handler.onRequest req
          if storedToken == some token then
            pure resp
          else
            match resp.extensions.get SessionUpdate with
            | some .delete => pure resp
            | update =>
              let baseData := match update with
                | some (.write d) => d
                | _ => sessionData.data
              let newData := (baseData.remove antiForgeryKey).set antiForgeryKey token
              pure { resp with extensions := resp.extensions.insert (SessionUpdate.write newData) } }

end Middleware
