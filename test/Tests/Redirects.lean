/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Redirects
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (sslRedirect absoluteRedirects forwardedScheme SslRedirectOptions)

namespace Tests.Redirects

-- The "no Host header" fallback branch documented on `sslRedirect`/`absoluteRedirects` isn't
-- exercised here: `Std.Http.Server` itself rejects a Host-less HTTP/1.1 request with `400`
-- before it ever reaches middleware (confirmed empirically, matching RFC 7230's requirement),
-- so that branch is unreachable through the real request-parsing path this test harness drives.

def bareHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "reached-inner" }

def redirectHandler (status : Status) (location : String) : StatelessHandler :=
  { onRequest := fun _ =>
      pure {
        line := {
          status,
          headers := Headers.empty.insert Middleware.Header.Name.location (Header.Value.ofString! location) },
        body := Body.Any.ofBody ({} : Body.Empty) } }

/-- `mkGet`/`mkGetClose` already send `Host: example.com`, so that's the host every test here
sees -- adding another `Host:` header ourselves would make the request itself invalid (multiple
`Host` headers), not exercise anything about `sslRedirect`/`absoluteRedirects`. -/
def sslRedirectHttpsPassthroughTest : IO Unit :=
  check "an already-https request passes through to the inner handler"
    (mkGet "/" "X-Forwarded-Proto: https\x0d\nConnection: close\x0d\n")
    (forwardedScheme Middleware.Header.Name.xForwardedProto
      (sslRedirect ({} : SslRedirectOptions) bareHandler)).onRequest fun response =>
      assertContains response "reached-inner"

def sslRedirectHttpGetTest : IO Unit :=
  check "a plain http GET gets a 301 to the same target over https" (mkGetClose "/path?x=1")
    (sslRedirect ({} : SslRedirectOptions) bareHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 301"
      assertContains response "Location: https://example.com/path?x=1"
      assertAbsent response "reached-inner"

def sslRedirectPostGets307Test : IO Unit :=
  check "a plain http POST gets a 307 (method/body-preserving), not a 301"
    (mkPost "/submit" "" "Connection: close\x0d\n")
    (sslRedirect ({} : SslRedirectOptions) bareHandler).onRequest fun response => do
      assertStatus response "HTTP/1.1 307"
      assertContains response "Location: https://example.com/submit"

def sslRedirectCustomPortTest : IO Unit :=
  check "a custom sslPort is appended to the host" (mkGetClose "/")
    (sslRedirect ({ sslPort := some 8443 } : SslRedirectOptions) bareHandler).onRequest fun response =>
      assertContains response "Location: https://example.com:8443/"

def nonRedirectPassthroughTest : IO Unit :=
  check "a 200 response is untouched" (mkGetClose "/") (absoluteRedirects bareHandler).onRequest
    fun response => assertContains response "reached-inner"

def alreadyAbsoluteLocationUntouchedTest : IO Unit :=
  check "an already-absolute Location is left alone" (mkGetClose "/")
    (absoluteRedirects (redirectHandler .found "https://other.example/target")).onRequest fun response =>
      assertContains response "Location: https://other.example/target"

def relativeLocationRewrittenTest : IO Unit :=
  check "a relative Location on a 302 is rewritten to an absolute one"
    (mkGet "/" "X-Forwarded-Proto: https\x0d\nConnection: close\x0d\n")
    (forwardedScheme Middleware.Header.Name.xForwardedProto
      (absoluteRedirects (redirectHandler .found "/target"))).onRequest fun response =>
      assertContains response "Location: https://example.com/target"

/-- `308` is deliberately excluded from `absoluteRedirects`'s redirect-status set
(`201 301 302 303 307`), so this is left untouched too. -/
def status308NotRewrittenTest : IO Unit :=
  check "308 is left untouched" (mkGetClose "/")
    (absoluteRedirects (redirectHandler .permanentRedirect "/target")).onRequest fun response =>
      assertContains response "Location: /target"

def run : IO Unit :=
  runGroup "Middleware.Redirects" do
    sslRedirectHttpsPassthroughTest
    sslRedirectHttpGetTest
    sslRedirectPostGets307Test
    sslRedirectCustomPortTest
    nonRedirectPassthroughTest
    alreadyAbsoluteLocationUntouchedTest
    relativeLocationRewrittenTest
    status308NotRewrittenTest

end Tests.Redirects
