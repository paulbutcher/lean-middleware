/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import CookieStoreTests

def main : IO Unit := do
  CookieStoreTests.AesGcm.run
  CookieStoreTests.Store.run
  IO.println "All tests passed."
