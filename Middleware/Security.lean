/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Core

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def xFrameOptions : Header.Name := .mk "x-frame-options"
def xContentTypeOptions : Header.Name := .mk "x-content-type-options"
def xXssProtection : Header.Name := .mk "x-xss-protection"
def strictTransportSecurity : Header.Name := .mk "strict-transport-security"

end Middleware.Header.Name

namespace Middleware

/-- Sets `name` to `value`, replacing any value(s) already there rather than adding a second
occurrence -- `Headers.insert` is additive (by design, for multi-value headers like
`Set-Cookie`), and `Headers.replaceLast` is a no-op when the header is absent, so neither alone
guarantees exactly one occurrence for a single-valued header. -/
private def setHeader (headers : Headers) (name : Header.Name) (value : String) : Headers :=
  (headers.erase name).insert name (Header.Value.ofString! value)

/-- `X-Frame-Options` (governs whether the page can be framed, a defense against clickjacking).
Browser support for `allowFrom` is incomplete. -/
inductive FrameOptions where
  | deny
  | sameOrigin
  | allowFrom (uri : String)

def FrameOptions.toWire : FrameOptions → String
  | .deny => "DENY"
  | .sameOrigin => "SAMEORIGIN"
  | .allowFrom uri => s!"ALLOW-FROM {uri}"

def xFrameOptions (options : FrameOptions := .sameOrigin) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        let headers := setHeader resp.line.headers Header.Name.xFrameOptions options.toWire
        pure { resp with line := { resp.line with headers } } }

/-- `X-Content-Type-Options: nosniff` -- stops browsers guessing a resource's MIME type from its
content, preventing e.g. an uploaded image being sniffed and executed as a script. -/
def xContentTypeOptions : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        let headers := setHeader resp.line.headers Header.Name.xContentTypeOptions "nosniff"
        pure { resp with line := { resp.line with headers } } }

/-- `X-XSS-Protection`, a legacy heuristic reflected-XSS filter most modern browsers have since
removed, kept here only for compatibility with older clients that still respect it. -/
inductive XssProtection where
  | disabled
  | enabled
  | enabledBlock

def XssProtection.toWire : XssProtection → String
  | .disabled => "0"
  | .enabled => "1"
  | .enabledBlock => "1; mode=block"

def xXssProtection (mode : XssProtection := .enabledBlock) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        let headers := setHeader resp.line.headers Header.Name.xXssProtection mode.toWire
        pure { resp with line := { resp.line with headers } } }

/-- Options for `hsts`. -/
structure HstsOptions where
  /-- Seconds the client should remember to only use HTTPS for this origin. -/
  maxAge : Nat := 31536000
  includeSubDomains : Bool := true

/-- Sets `Strict-Transport-Security` (RFC 6797) on every response, unconditionally -- this
middleware doesn't itself verify the connection is actually secure; enabling it is a deployment
decision. -/
def hsts (options : HstsOptions := {}) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        let value :=
          s!"max-age={options.maxAge}" ++ (if options.includeSubDomains then "; includeSubDomains" else "")
        let headers := setHeader resp.line.headers Header.Name.strictTransportSecurity value
        pure { resp with line := { resp.line with headers } } }

end Middleware
