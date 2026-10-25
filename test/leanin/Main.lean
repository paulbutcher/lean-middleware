/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import LeanInTests.Suite

def main : IO Unit := do
  LeanInTests.all
  IO.println "All LeanIn tests passed."
