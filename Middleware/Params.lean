/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core

public section

open Std.Http
open Std.Http.Server

namespace Middleware

/-- Query-string and form-body parameters extracted from a request. -/
structure Params where
  query : URI.Query := .empty
  form : URI.Query := .empty
deriving TypeName

namespace Params

private def lookup (query : URI.Query) (key : String) : Option String :=
  (query.toArray.find? fun (name, _) => name.decode == some key).bind fun (_, value) =>
    match value with
    | none => some ""
    | some encoded => encoded.decode

/--
Looks up a parameter by its decoded name. Percent-encoding is not canonical, so a name can arrive
spelled differently from the way it was written: browsers encode form field names far more
aggressively than RFC 3986 requires, posting `a:b` as `a%3Ab`. Every spelling that decodes to
`key` is therefore the same parameter, and a name whose bytes are not valid UTF-8 matches nothing.

Form-body values take precedence over query-string values. A name present with no value reads as
`some ""`, which callers can distinguish from the `none` of an absent name.

This does mean `a b`, `a+b` and `a%20b` are one name. Callers that need to tell two encoded
spellings apart have `Params.query` and `Params.form`, and can work on `URI.EncodedQueryParam`
directly.
-/
def get (p : Params) (key : String) : Option String :=
  (lookup p.form key).orElse (fun _ => lookup p.query key)

end Params

namespace ContentType.FormUrlEncoded

/-- Parses an `application/x-www-form-urlencoded` body into a `URI.Query`. -/
def parse (body : String) : URI.Query :=
  let pairs := if body.isEmpty then [] else body.splitOn "&"
  pairs.foldl (init := (URI.Query.empty : URI.Query)) fun acc pair =>
    if pair.isEmpty then acc
    else
      match pair.splitOn "=" with
      | [] => acc
      | key :: rest =>
        match URI.EncodedQueryParam.fromString? key with
        | none => acc
        | some encodedKey =>
          match rest with
          | [] => acc.insertEncoded encodedKey none
          | _ =>
            match URI.EncodedQueryParam.fromString? (String.intercalate "=" rest) with
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
