/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Core

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def xForwardedProto : Header.Name := .mk "x-forwarded-proto"
def xForwardedFor : Header.Name := .mk "x-forwarded-for"

end Middleware.Header.Name

namespace Middleware

/-- The scheme (`http`/`https`) a trusted reverse proxy reports the client actually used.
`Std.Http.Server` has no built-in TLS support and so no native notion of scheme at all -- this is
the only way anything in this library ever learns it. -/
inductive Scheme where
  | http
  | https
deriving TypeName, BEq

/-- Attaches a `Scheme` extension from `headerName` (default `X-Forwarded-Proto`), when its value
is (case-insensitively) exactly `http` or `https`. Any other value -- including absent -- leaves
the request untouched, treated as "no information provided" rather than an error. -/
def forwardedScheme (headerName : Header.Name := Header.Name.xForwardedProto) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let scheme? := (req.line.headers.get? headerName).bind fun v =>
          match v.value.trimAscii.toString.toLower with
          | "http" => some Scheme.http
          | "https" => some Scheme.https
          | _ => none
        match scheme? with
        | none => handler.onRequest req
        | some scheme =>
          handler.onRequest { req with extensions := req.extensions.insert scheme } }

/-- The client address a trusted reverse proxy reports, from the last comma-separated entry of
`X-Forwarded-For` -- a single-hop-trusted-proxy assumption, same as Ring's own
`wrap-forwarded-remote-addr`: safe only when exactly one proxy you trust sits directly in front
of this server and unconditionally appends the real client address. A bare string, not
`Std.Http.Server.RemoteAddr` (`Net.SocketAddress`), since `X-Forwarded-For` carries no port. -/
structure ForwardedFor where
  addr : String
deriving TypeName

/-- Attaches a `ForwardedFor` extension from the last comma-separated entry of `headerName`
(default `X-Forwarded-For`), if present. -/
def forwardedRemoteAddr (headerName : Header.Name := Header.Name.xForwardedFor) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        match req.line.headers.get? headerName with
        | none => handler.onRequest req
        | some v =>
          match (v.value.splitOn ",").getLast? with
          | none => handler.onRequest req
          | some last =>
            let req := { req with
              extensions := req.extensions.insert ({ addr := last.trimAscii.toString } : ForwardedFor) }
            handler.onRequest req }

/-- `scheme://host` for the current request, using the `Scheme` extension (`forwardedScheme`) if
present, else assuming `http` -- the safe-failure default for security-sensitive callers
(`sslRedirect`/`absoluteRedirects`): this server has no other way to know, and silently assuming
`https` would be the actively unsafe direction to guess wrong in. `none` if there's no `Host`
header to build from. -/
def requestOrigin (req : Request Body.Stream) : Option String :=
  (req.line.headers.get? Header.Name.host).map fun hostValue =>
    let scheme := match (req.extensions.get Scheme).getD .http with
      | .http => "http"
      | .https => "https"
    s!"{scheme}://{hostValue.value}"

end Middleware
