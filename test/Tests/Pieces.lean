/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import RoutingStd
public import Std.Http.Test.Helpers

public section

open Std.Http
open Routing
open Std.Http.Internal.Test

namespace Tests.Pieces

/-- `raw` in pieces of at most `piece` bytes. -/
def piecesOf (raw : ByteArray) (piece : Nat := 8192) : List ByteArray :=
  (List.range ((raw.size + piece - 1) / piece)).map fun i =>
    raw.extract (i * piece) ((i + 1) * piece)

/-- `check` for a request sent a piece at a time, so that a body larger than a piece reaches the
handler over several reads however the transport would have split a single write. Takes bytes,
which also lets it carry a body that is not UTF-8. -/
def checkInPieces (name : String) (raw : ByteArray) (handler : StatelessHandler .std)
    (expect : ByteArray → IO Unit) : IO Unit := do
  let (client, server) ← Std.Http.Internal.Mock.new
  let response ← Std.Async.Async.block do
    for piece in piecesOf raw do
      client.send piece
    Std.Http.Server.serveConnection server handler defaultConfig |>.run
    pure ((← client.recv?).getD .empty)
  try expect response
  catch err => throw (IO.userError s!"[{name}] {err}")

end Tests.Pieces
