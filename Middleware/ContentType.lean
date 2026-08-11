/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Core

open Std.Http
open Std.Http.Server

namespace Middleware.ContentType

/-- File-extension to MIME-type table used to infer `Content-Type` from a request path. -/
def mimeTypes : List (String × String) :=
  [("html", "text/html; charset=utf-8"),
   ("htm", "text/html; charset=utf-8"),
   ("css", "text/css; charset=utf-8"),
   ("js", "text/javascript; charset=utf-8"),
   ("json", "application/json"),
   ("txt", "text/plain; charset=utf-8"),
   ("xml", "application/xml"),
   ("png", "image/png"),
   ("jpg", "image/jpeg"),
   ("jpeg", "image/jpeg"),
   ("gif", "image/gif"),
   ("svg", "image/svg+xml"),
   ("ico", "image/x-icon"),
   ("pdf", "application/pdf"),
   ("woff", "font/woff"),
   ("woff2", "font/woff2")]

/-- The extension of the final path segment (the part after the last `.`), if any. -/
def extensionOf (path : URI.Path) : Option String :=
  match path.segments.back? with
  | none => none
  | some seg =>
    match (toString seg).splitOn "." with
    | [] | [_] => none
    | parts => parts.getLast?

/-- Looks up the MIME type for a file extension, case-insensitively. -/
def lookup (ext : String) : Option String :=
  (mimeTypes.find? (fun (k, _) => k == ext.toLower)).map Prod.snd

end Middleware.ContentType

namespace Middleware

/--
Sets the `Content-Type` response header by inferring it from the request path's file
extension, when the handler hasn't already set one. Falls back to `default` for unknown or
missing extensions.
-/
def contentType (default : String := "application/octet-stream") : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        if resp.line.headers.contains Header.Name.contentType then
          pure resp
        else
          let mime := ((ContentType.extensionOf req.line.uri.path).bind ContentType.lookup).getD default
          pure { resp with
            line := { resp.line with
              headers := resp.line.headers.insert Header.Name.contentType (Header.Value.ofString! mime) } } }

end Middleware
