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
  Tests.Cookies.run
  Tests.Session.run
  Tests.Flash.run
  Tests.Security.run
  Tests.Charset.run
  Tests.Proxy.run
  Tests.Redirects.run
  Tests.AntiForgery.run
  Tests.Crypto.AesGcm.run
  Tests.Crypto.Base64.run
  Tests.CookieStore.run
  Tests.Integration.run
  IO.println "All tests passed."
