/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Security
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test
open Middleware (xFrameOptions xContentTypeOptions xXssProtection hsts FrameOptions XssProtection
  HstsOptions)

namespace Tests.Security

def bareHandler : StatelessHandler :=
  { onRequest := fun _ => Response.ok |>.text "ok" }

def preSetHandler (name value : String) : StatelessHandler :=
  { onRequest := fun _ =>
      Response.ok.header! name value |>.text "ok" }

def frameOptionsDefaultTest : IO Unit :=
  check "defaults to SAMEORIGIN" (mkGetClose "/") (xFrameOptions .sameOrigin bareHandler).onRequest
    fun response => assertContains response "X-Frame-Options: SAMEORIGIN"

def frameOptionsDenyTest : IO Unit :=
  check "deny renders DENY" (mkGetClose "/") (xFrameOptions .deny bareHandler).onRequest
    fun response => assertContains response "X-Frame-Options: DENY"

def frameOptionsAllowFromTest : IO Unit :=
  check "allowFrom renders ALLOW-FROM <uri>" (mkGetClose "/")
    (xFrameOptions (.allowFrom "https://example.com") bareHandler).onRequest fun response =>
      assertContains response "X-Frame-Options: ALLOW-FROM https://example.com"

def frameOptionsNoDuplicateTest : IO Unit :=
  check "doesn't duplicate a header the handler already set" (mkGetClose "/")
    (xFrameOptions .deny (preSetHandler "X-Frame-Options" "SAMEORIGIN")).onRequest fun response => do
      let text := String.fromUTF8! response
      let occurrences := (text.splitOn "X-Frame-Options:").length - 1
      unless occurrences == 1 do
        throw <| IO.userError s!"expected exactly one X-Frame-Options header, found {occurrences}"
      assertContains response "X-Frame-Options: DENY"

/-- A CRLF in an application-supplied value neither splits the response nor costs the header its
value; the value is stripped of what it can't legally carry and sent anyway. -/
def frameOptionsHeaderInjectionTest : IO Unit :=
  check "a CRLF in allowFrom neither splits the response nor empties the header" (mkGetClose "/")
    (xFrameOptions (.allowFrom "https://example.com\x0d\nX-Evil: 1") bareHandler).onRequest
    fun response => do
      assertStatus response "HTTP/1.1 200"
      assertAbsent response "\x0d\nX-Evil:"
      assertAbsent response "X-Frame-Options: \x0d\n"
      assertContains response "X-Frame-Options: ALLOW-FROM https://example.com"

def contentTypeOptionsTest : IO Unit :=
  check "always nosniff" (mkGetClose "/") (xContentTypeOptions bareHandler).onRequest
    fun response => assertContains response "X-Content-Type-Options: nosniff"

def xssProtectionDefaultTest : IO Unit :=
  check "defaults to enabledBlock" (mkGetClose "/") (xXssProtection .enabledBlock bareHandler).onRequest
    fun response => assertContains response "X-Xss-Protection: 1; mode=block"

def xssProtectionDisabledTest : IO Unit :=
  check "disabled renders 0" (mkGetClose "/") (xXssProtection .disabled bareHandler).onRequest
    fun response => assertContains response "X-Xss-Protection: 0"

def hstsDefaultTest : IO Unit :=
  check "defaults to a one-year max-age with includeSubDomains" (mkGetClose "/")
    (hsts ({} : HstsOptions) bareHandler).onRequest fun response =>
      assertContains response "Strict-Transport-Security: max-age=31536000; includeSubDomains"

def hstsCustomTest : IO Unit :=
  check "custom maxAge without includeSubDomains" (mkGetClose "/")
    (hsts ({ maxAge := 3600, includeSubDomains := false } : HstsOptions) bareHandler).onRequest
    fun response => do
      assertContains response "Strict-Transport-Security: max-age=3600"
      assertAbsent response "includeSubDomains"

def run : IO Unit :=
  runGroup "Middleware.Security" do
    frameOptionsDefaultTest
    frameOptionsDenyTest
    frameOptionsAllowFromTest
    frameOptionsNoDuplicateTest
    frameOptionsHeaderInjectionTest
    contentTypeOptionsTest
    xssProtectionDefaultTest
    xssProtectionDisabledTest
    hstsDefaultTest
    hstsCustomTest

end Tests.Security
