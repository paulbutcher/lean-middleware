/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Tests

def main : IO Unit := do
  Tests.Core.run
  Tests.CatchAll.run
  Tests.ContentType.run
  Tests.Params.run
  Tests.NotModified.run
  Tests.File.run
  Tests.Multipart.run
  IO.println "All tests passed."
