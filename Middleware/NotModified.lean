/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core
public import Middleware.HeaderValue
public import Std.Time

public section

open Std.Http
open Std.Http.Server

namespace Middleware.Header.Name

def etag : Header.Name := .mk "etag"
def ifNoneMatch : Header.Name := .mk "if-none-match"
def lastModified : Header.Name := .mk "last-modified"
def ifModifiedSince : Header.Name := .mk "if-modified-since"

end Middleware.Header.Name

namespace Middleware

/-- An HTTP entity tag (RFC 9110 §8.8.3): an opaque validator, optionally weak. -/
structure ETag where
  value : String
  weak : Bool := false
deriving BEq, Repr

namespace ETag

private def parseWire (s : String) : Option ETag :=
  let (weak, rest) : Bool × String :=
    if s.startsWith "W/" then (true, (s.drop 2).toString) else (false, s)
  match rest.toList with
  | '"' :: t =>
    match t.getLast? with
    | some '"' =>
      let inner := t.dropLast
      if inner.all Std.Http.Internal.Char.etagc then
        some { value := String.ofList inner, weak }
      else
        none
    | _ => none
  | _ => none

/-- Parses `"..."` or `W/"..."`, validating the inner characters against `etagc`. -/
def parse (v : Header.Value) : Option ETag :=
  parseWire v.value

/-- Renders `"..."` or `W/"..."`, dropping from `value` anything `etagc` doesn't admit --
notably `"` itself -- so an application-built tag can't escape its own quotes. -/
def serialize (e : ETag) : Header.Name × Header.Value :=
  let inner := String.ofList (e.value.toList.filter Std.Http.Internal.Char.etagc)
  let raw := (if e.weak then "W/\"" else "\"") ++ inner ++ "\""
  (Middleware.Header.Name.etag, Header.Value.ofStringSanitized raw)

instance : Header ETag := ⟨parse, serialize⟩

/-- Weak comparison (RFC 9110 §8.8.3.2): equal iff the opaque tags are equal, ignoring `weak`. -/
@[expose] def weakMatches (a b : ETag) : Bool :=
  a.value == b.value

end ETag

/-- The `Last-Modified` response header. -/
structure LastModified where
  date : Std.Time.DateTime

namespace LastModified

def parse (v : Header.Value) : Option LastModified :=
  match Std.Time.DateTime.fromRFC822String v.value with
  | .ok d => some { date := d }
  | .error _ => none

def serialize (lm : LastModified) : Header.Name × Header.Value :=
  (Middleware.Header.Name.lastModified, Header.Value.ofStringSanitized lm.date.toRFC822String)

instance : Header LastModified := ⟨parse, serialize⟩

end LastModified

/-- The `If-Modified-Since` request header. Parsed leniently: RFC 9110 §5.6.7 requires servers to
accept the obsolete RFC 850 and asctime date formats in addition to RFC 822/1123. -/
structure IfModifiedSince where
  date : Std.Time.DateTime

namespace IfModifiedSince

def parse (v : Header.Value) : Option IfModifiedSince :=
  match Std.Time.DateTime.parse v.value with
  | .ok d => some { date := d }
  | .error _ => none

def serialize (i : IfModifiedSince) : Header.Name × Header.Value :=
  (Middleware.Header.Name.ifModifiedSince, Header.Value.ofStringSanitized i.date.toRFC822String)

instance : Header IfModifiedSince := ⟨parse, serialize⟩

end IfModifiedSince

/-- The `If-None-Match` request header: either `*`, or a comma-separated list of entity tags. -/
inductive IfNoneMatch where
  | any
  | tags (etags : List ETag)

namespace IfNoneMatch

def parse (v : Header.Value) : Option IfNoneMatch :=
  let s := v.value.trimAscii.toString
  if s == "*" then
    some .any
  else
    let tags := (s.splitOn ",").filterMap fun part =>
      ETag.parseWire part.trimAscii.toString
    if tags.isEmpty then none else some (.tags tags)

def serialize (i : IfNoneMatch) : Header.Name × Header.Value :=
  match i with
  | .any => (Middleware.Header.Name.ifNoneMatch, Header.Value.ofStringSanitized "*")
  | .tags ts =>
    let rendered := ts.map (fun t => (ETag.serialize t).snd.value)
    (Middleware.Header.Name.ifNoneMatch,
      Header.Value.ofStringSanitized (String.intercalate ", " rendered))

instance : Header IfNoneMatch := ⟨parse, serialize⟩

/-- Whether `e` matches this `If-None-Match` value under weak comparison. -/
@[expose] def matchesTag (i : IfNoneMatch) (e : ETag) : Bool :=
  match i with
  | .any => true
  | .tags ts => ts.any (ETag.weakMatches · e)

end IfNoneMatch

/--
Downgrades a response to `304 Not Modified` when the request's `If-None-Match` or
`If-Modified-Since` headers indicate the client's cached copy is still current, based on the
response's own `ETag`/`Last-Modified` headers (typically set by another middleware, e.g. `file`).
`If-None-Match` takes precedence over `If-Modified-Since` when both are present (RFC 9110 §13.1.1).

The `304` response keeps only the `ETag`/`Last-Modified` headers from the original response. A
fully spec-precise `304` would also preserve `Cache-Control`/`Vary`/`Expires`; this library
doesn't have middleware for those yet, so this is a deliberate simplification.
-/
def notModified : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        let respETag := (resp.line.headers.get? Header.Name.etag).bind ETag.parse
        let respLastModified :=
          (resp.line.headers.get? Header.Name.lastModified).bind LastModified.parse
        let ifNoneMatch := (req.line.headers.get? Header.Name.ifNoneMatch).bind IfNoneMatch.parse
        let ifModifiedSince :=
          (req.line.headers.get? Header.Name.ifModifiedSince).bind IfModifiedSince.parse

        let isNotModified : Bool :=
          match ifNoneMatch, respETag with
          | some inm, some etag => inm.matchesTag etag
          | some _, none => false
          | none, _ =>
            match ifModifiedSince, respLastModified with
            | some ims, some lm => decide (lm.date.toTimestamp ≤ ims.date.toTimestamp)
            | _, _ => false

        if isNotModified then
          let mut headers := Headers.empty
          if let some etag := respETag then
            headers := headers.insert (ETag.serialize etag).fst (ETag.serialize etag).snd
          if let some lm := respLastModified then
            headers := headers.insert (LastModified.serialize lm).fst (LastModified.serialize lm).snd
          pure {
            line := { status := .notModified, version := resp.line.version, headers },
            body := Body.Any.ofBody ({} : Body.Empty) }
        else
          pure resp }

end Middleware
