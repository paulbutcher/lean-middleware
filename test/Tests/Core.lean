/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Middleware.Core
public import Std.Http.Test.Helpers

public section

open Std.Http
open Std.Http.Server
open Std.Http.Internal.Test

namespace Tests.Core

/--
A stack can be split anywhere and applied in pieces. This is what makes the ordering recommended
in `Middleware.apply`'s documentation composable: an application can group its middleware however
it likes, or drop the ones it doesn't use, and the relative order of what remains still means the
same thing.

For any two middleware lists `mws₁` and `mws₂` and any base handler, applying the concatenation
gives literally the same handler as applying `mws₂` to the base and then applying `mws₁` to that.
Equality here is of `StatelessHandler` values, not of observed responses, so the claim is that
the two groupings build the same handler rather than merely two handlers that happen to agree on
the requests a test tries.
-/
theorem apply_append (mws₁ mws₂ : List Middleware) (base : StatelessHandler) :
    Middleware.apply (mws₁ ++ mws₂) base = Middleware.apply mws₁ (Middleware.apply mws₂ base) := by
  simp [Middleware.apply]

/--
The empty stack is the identity on handlers. An application that assembles its list conditionally
and ends up adding nothing gets back exactly the handler it started with, so there is no
"wrapped in nothing" case behaving differently from the unwrapped one.

For any base handler, `Middleware.apply []` returns that same handler. The proof is `rfl`, so the
two are equal by unfolding alone, which is the strongest form the claim admits.
-/
theorem apply_nil (base : StatelessHandler) : Middleware.apply [] base = base := rfl

/--
`Middleware.id` can sit anywhere in a stack without changing what that stack does, so it is
usable as a placeholder for a layer that is only sometimes enabled: an application can keep the
shape of its list fixed and swap a real middleware for `id` rather than building two lists.

For any middleware list `mws` and base handler, putting `Middleware.id` at the head of the list
yields the same handler as leaving it out. Combined with `apply_append`, which lets the list be
cut at any point, this covers `id` at any position, not just the head.
-/
theorem apply_id_cons (mws : List Middleware) (base : StatelessHandler) :
    Middleware.apply (Middleware.id :: mws) base = Middleware.apply mws base := rfl

/-- Adds an `x-order` header on the way back out, recording when this layer ran. -/
def markerMiddleware (name : String) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        let resp ← handler.onRequest req
        pure { resp with
          line := { resp.line with headers := resp.line.headers.insert! "x-order" name } } }

def baseHandler : TestHandler := fun _ => Response.ok |>.text "base"

/--
`Middleware.apply` runs pre-processing outermost-first, so post-processing (like the header
insertion here) happens innermost-first: with `[markerMiddleware "A", markerMiddleware "B"]`,
"B" wraps the base handler and finishes its post-processing before "A" does, so "B"'s header
is inserted first.
-/
def orderTest : IO Unit := do
  let stack := Middleware.apply [markerMiddleware "A", markerMiddleware "B"]
    { onRequest := baseHandler }
  check "middleware order" (mkGetClose) stack.onRequest fun response => do
    let text := String.fromUTF8! response
    assertContains response "X-Order: B"
    assertContains response "X-Order: A"
    let beforeA := (text.splitOn "X-Order: A").head!
    unless (beforeA.splitOn "X-Order: B").length > 1 do
      throw <| IO.userError s!"expected 'X-Order: B' before 'X-Order: A', got:\n{text.quote}"

def run : IO Unit :=
  runGroup "Middleware.Core" do
    orderTest

end Tests.Core
