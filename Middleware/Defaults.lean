/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.CacheControl
public import Middleware.CatchAll
public import Middleware.Charset
public import Middleware.ContentType
public import Middleware.Cors
public import Middleware.Flash
public import Middleware.AntiForgery
public import Middleware.NotModified
public import Middleware.Redirects
public import Middleware.Security

public section

open Std.Http
open Routing

namespace Middleware

variable {e : Engine} [ServerEngine e]

/-- The headers `forwardedScheme` and `forwardedRemoteAddr` trust. -/
structure ProxyHeaders where
  scheme : Header.Name := Header.Name.xForwardedProto
  remoteAddr : Header.Name := Header.Name.xForwardedFor

/--
Which of this library's middleware `defaults` applies, and with what options. `{}` applies none;
start from one of the presets instead and override what differs.

A layer that takes its prerequisites from outside this package, or that only the application can
configure, is a slot holding a ready-made `Middleware e`: `tracing` for `serverSpan`, `session`
for `session` over the application's store, and `static` for `file` and `assets`, composed with
`∘` when both are wanted.
-/
structure Defaults (e : Engine) [ServerEngine e] where
  proxy : Option ProxyHeaders := none
  hsts : Option HstsOptions := none
  frameOptions : Option FrameOptions := none
  contentTypeOptions : Bool := false
  xssProtection : Option XssProtection := none
  cors : Option (CorsOptions e) := none
  catchAll : Bool := false
  tracing : Middleware e := Middleware.id
  sslRedirect : Option SslRedirectOptions := none
  cookies : Bool := false
  session : Middleware e := Middleware.id
  flash : Bool := false
  params : Option ParamsOptions := none
  multipartParams : Option MultipartOptions := none
  antiForgery : Option (AntiForgeryOptions e) := none
  absoluteRedirects : Bool := false
  /-- The `Content-Type` for a path whose extension names none. -/
  contentType : Option String := none
  defaultCharset : Option String := none
  cacheControl : Option CachePolicy := none
  notModified : Bool := false
  static : Middleware e := Middleware.id

private def layerOf {α : Type} (options : Option α) (mw : α → Middleware e) : Middleware e :=
  options.elim Middleware.id mw

private def layerIf (enabled : Bool) (mw : Middleware e) : Middleware e :=
  if enabled then mw else Middleware.id

/-- Applies the layers `d` enables, in the order `Middleware.apply`'s doc comment sets out. -/
def defaults (d : Defaults e) : Middleware e :=
  Middleware.apply
    [layerOf d.proxy fun p => forwardedScheme p.scheme ∘ forwardedRemoteAddr p.remoteAddr,
     layerOf d.hsts (hsts ·),
     layerOf d.frameOptions (xFrameOptions ·),
     layerIf d.contentTypeOptions xContentTypeOptions,
     layerOf d.xssProtection (xXssProtection ·),
     layerOf d.cors (cors ·),
     layerIf d.catchAll catchAll,
     d.tracing,
     layerOf d.sslRedirect (sslRedirect ·),
     layerIf d.cookies cookies,
     d.session,
     layerIf d.flash flash,
     layerOf d.params (params ·),
     layerOf d.multipartParams (multipartParams ·),
     layerOf d.antiForgery (antiForgery ·),
     layerIf d.absoluteRedirects absoluteRedirects,
     layerOf d.contentType (contentType ·),
     layerOf d.defaultCharset (defaultCharset ·),
     layerOf d.cacheControl (cacheControl ·),
     layerIf d.notModified notModified,
     d.static]

/-- An API serving machine clients over plain HTTP. -/
def apiDefaults : Defaults e :=
  { catchAll := true,
    params := some {},
    absoluteRedirects := true,
    contentType := some "application/octet-stream",
    defaultCharset := some "utf-8",
    cacheControl := some .noCache,
    notModified := true }

/-- `apiDefaults` behind a TLS-terminating proxy, the only way a request here can have arrived over
`https`: without `proxy`, `sslRedirect` would see every request as `http` and redirect it
forever. -/
def secureApiDefaults : Defaults e :=
  { apiDefaults with
    proxy := some {},
    hsts := some {},
    sslRedirect := some {} }

/-- A browser-facing site over plain HTTP, its sessions kept in `store`. -/
def siteDefaults [SessionStore σ] (store : σ) : Defaults e :=
  { apiDefaults with
    frameOptions := some .sameOrigin,
    contentTypeOptions := true,
    cookies := true,
    session := session store,
    flash := true,
    multipartParams := some {},
    antiForgery := some {} }

/-- `siteDefaults` behind a TLS-terminating proxy, as `secureApiDefaults` is. The session cookie is
`Secure`, and named apart from `siteDefaults`' so that a cookie set over plain HTTP cannot stand
in for it. -/
def secureSiteDefaults [SessionStore σ] (store : σ) : Defaults e :=
  { siteDefaults store with
    proxy := some {},
    hsts := some {},
    sslRedirect := some {},
    session := session store
      { cookieName := "secure-lean-session",
        cookieAttrs := { path := some "/", httpOnly := true, secure := true } } }

end Middleware
