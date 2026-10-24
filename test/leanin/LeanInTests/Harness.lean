/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import RoutingLeanIn

/-!
Running a handler on LeanIn in memory, without a socket, through `toLeanIn` so that what runs is
what LeanIn would serve.
-/

namespace LeanInTests

open Routing
open Std.Http

structure Outcome where
  status : Status
  headers : Headers
  body : ByteArray

def Outcome.text (o : Outcome) : String :=
  (String.fromUTF8? o.body).getD "<not UTF-8>"

def Outcome.header? (o : Outcome) (name : String) : Option String :=
  (Header.Name.ofString? name).bind fun n => (o.headers.get? n).map (·.value)

def Outcome.headers? (o : Outcome) (name : String) : List String :=
  ((Header.Name.ofString? name).bind fun n => o.headers.getAll? n).map (·.toList.map (·.value))
    |>.getD []

def check (label : String) (ok : Bool) : IO Unit :=
  unless ok do throw (IO.userError label)

def runVM (m : LeanIn.Runtime.VM α) : IO α := do
  let cell ← LeanIn.Runtime.RawCell.new
  LeanIn.Runtime.VM.runToCell m cell
  let out ← IO.mkRef none
  LeanIn.Runtime.RawCell.await cell (fun v => out.set (some v))
  match ← out.get with
  | some v => pure v
  | none => throw (IO.userError "the VM suspended, which no handler here should")

/-- A reader handing out `body` in pieces no larger than each `recv` asks for, as LeanIn's driver
does, so that a body larger than one read arrives over several. -/
def readerOf (body : ByteArray) : IO LeanIn.Http.Server.BodyReader := do
  let rest ← IO.mkRef body
  return { recv := fun n => (rest.modifyGet fun r =>
             if r.isEmpty then (none, r)
             else
               let k := min (max n 1) r.size
               (some (r.extract 0 k), r.extract k r.size) : IO _)
           drained := ((·.isEmpty) <$> rest.get : IO _)
           leftover := pure .empty }

def bytesOf : LeanIn.Http.ResponseBody → LeanIn.Runtime.VM ByteArray
  | .bytes data => pure data
  | .stream _ write => do
    let acc ← (IO.mkRef ByteArray.empty : IO _)
    write fun chunk => (acc.modify (· ++ chunk) : IO Unit)
    (acc.get : IO _)

def run (h : StatelessHandler .leanin) (method : Method) (target : String)
    (headers : List (String × String) := []) (body : ByteArray := .empty) : IO Outcome := do
  let some uri := RequestTarget.parse? target
    | throw (IO.userError s!"test target {target.quote} is not a valid request target")
  let headers := headers.foldl (init := Headers.empty) fun hs (name, value) =>
    match Header.Name.ofString? name, Header.Value.ofString? value with
    | some n, some v => hs.insert n v
    | _, _ => hs
  let line : Request.Head := { method, version := .v11, uri, headers }
  let body ← readerOf body
  runVM do
    let response ← h.toLeanIn.onRequest { line, body }
    return { status := response.line.status, headers := response.line.headers
             body := ← bytesOf response.body }

end LeanInTests
