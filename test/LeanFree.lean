/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware
public import RoutingStd
public import Std.Http.Test.Helpers

/-!
A whole consumer of this library, built as an executable, that uses `extract`.
`scripts/check-runtime.sh` builds it and reads the Lean package's absence off the binary.

It is a `module` because a legacy file's initialiser runs the meta initialiser of everything it
imports, which would start the frontend at run time and link it in.
-/

public section

open Std.Http
open Routing
open Std.Http.Internal.Test
open Middleware

def greet : StatelessHandler .std :=
  { onRequest := extract (name ← Extract.field "name") (title ← Extract.field? "title") =>
      fun _ => Response.ok.text s!"hello {title.getD ""} {name}" }

def statusAndBody (response : ByteArray) : String :=
  let text := String.fromUTF8? response |>.getD ""
  let lines := text.splitOn "\x0d\n"
  s!"{lines.headD ""} / {lines.getLastD ""}"

def main : IO Unit := do
  for query in ["/?name=Ada&title=Countess", "/?title=Countess"] do
    check query (mkGetClose query) (params {} greet).onRequest fun response =>
      IO.println (statusAndBody response)
