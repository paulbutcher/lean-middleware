/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Middleware.Core

open Std.Http
open Std.Http.Server

namespace Middleware

/-- Query-string and form-body parameters extracted from a request. -/
structure Params where
  query : URI.Query := .empty
  form : URI.Query := .empty
deriving TypeName

namespace Params

/-- Looks up a parameter by key. Form-body values take precedence over query-string values. -/
def get (p : Params) (key : String) : Option String :=
  (p.form.get key).orElse (fun _ => p.query.get key)

end Params

namespace ContentType.FormUrlEncoded

/-- Replaces `application/x-www-form-urlencoded`'s `+`-for-space encoding with `%20`. -/
private def unescapePlus (s : String) : String :=
  String.intercalate "%20" (s.splitOn "+")

/-- Parses an `application/x-www-form-urlencoded` body into a `URI.Query`. -/
def parse (body : String) : URI.Query :=
  let pairs := if body.isEmpty then [] else body.splitOn "&"
  pairs.foldl (init := (URI.Query.empty : URI.Query)) fun acc pair =>
    if pair.isEmpty then acc
    else
      match pair.splitOn "=" with
      | [] => acc
      | key :: rest =>
        match URI.EncodedQueryParam.fromString? (unescapePlus key) with
        | none => acc
        | some encodedKey =>
          match rest with
          | [] => acc.insertEncoded encodedKey none
          | _ =>
            match URI.EncodedQueryParam.fromString? (unescapePlus (String.intercalate "=" rest)) with
            | none => acc
            | some encodedValue => acc.insertEncoded encodedKey (some encodedValue)

end ContentType.FormUrlEncoded

/--
Attaches a `Params` extension to the request, combining the query string (always present) with
the `application/x-www-form-urlencoded` body (when the request declares that content type). When
the body is read, it is replaced with an equivalent in-memory body so downstream middleware and
the handler can still read it.
-/
def params : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let query := req.line.uri.query
        let isFormUrlEncoded :=
          match req.line.headers.get? Header.Name.contentType with
          | some v => v.value.trimAscii.toString.toLower.startsWith "application/x-www-form-urlencoded"
          | none => false
        if isFormUrlEncoded then
          let bodyText ← req.body.readAll (α := String)
          let form := ContentType.FormUrlEncoded.parse bodyText
          let freshBody ← Body.fromBytes bodyText.toUTF8
          let req := { req with
            body := freshBody
            extensions := req.extensions.insert ({ query, form } : Params) }
          handler.onRequest req
        else
          let req := { req with extensions := req.extensions.insert ({ query } : Params) }
          handler.onRequest req }

end Middleware
