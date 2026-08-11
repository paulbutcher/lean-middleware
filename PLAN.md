# Ring-inspired middleware for Std.Http.Server — Phase 1 & 2

## Status: implemented (with one scope correction, see below)

Phase 1 and Phase 2 are done, `lake build` and `lake test` pass clean with no
warnings. One material change from the original plan: **`Middleware/Head.lean`
and `Middleware/ContentLength.lean` were dropped.** Verification against the
toolchain source (`Std/Http/Protocol/H1.lean:882`, `Server/Connection.lean`'s
`applyResponse`/`maybeSuppressOutgoingBody`) showed the server's own H1 writer
already: (a) computes `Content-Length` from the body's `getKnownSize` for any
response with a fixed-size body, and (b) detects `HEAD` requests from the
already-parsed request line and suppresses the outgoing body while still
computing headers as if it were `GET` — both entirely at the transport layer,
regardless of what the application handler does. Unlike Ring (built on Java's
Servlet API, where the application is responsible for both), this Lean stack
already gets them for free, so standalone middleware for either would be dead
code. `Middleware/ContentType.lean` has no such overlap (confirmed nothing in
`Connection.lean`/`H1.lean` touches `Content-Type`) and was implemented as
planned. Final Phase 2 middleware: `catchAll`, `contentType`, `params`.

Other deltas from the original plan, worth keeping for future phases:
- Adding Plausible required `[[require]]` in `lakefile.toml`. Pin the `rev` to
  a tag matching the project's toolchain (`v4.33.0` here) — letting `lake
  update` track a dependency's default branch silently bumped this repo's own
  `lean-toolchain` to an unrelated release candidate as a side effect; revert
  and re-pin explicitly if that happens again.
- `lake test`'s test-driver executable can't just import loose files under a
  `Tests/` directory — Lake needs those declared as their own `[[lean_lib]]`
  target (here, `Tests`), with a separate `Main.lean` (`[[lean_exe]] root =
  "Main"`) as the actual entrypoint. Naming the exe's root the same as a
  directory of importable modules doesn't work.
- Plausible's `Testable.checkIO` (used from plain `IO`, as opposed to
  `Testable.check` in `CoreM`) does **not** auto-decorate `∀`-binders — every
  quantifier needs an explicit `Plausible.NamedBinder "name" <| ∀ x, ...`
  wrapper or instance resolution fails. Also avoid `let`-bindings inside the
  tested `Prop` itself; factor the computation into an ordinary `Bool`-valued
  helper `def` and state the property as `... = true` instead.
- Test requests must use `mkGetClose`/set `Connection: close` explicitly (or
  drain via `checkClose`) — a plain `mkGet` leaves the mock connection open
  for keep-alive and `Std.Http.Internal.Test.check` will block for the
  duration of the connection's keep-alive/header timeout before returning.

## Context

We've been discussing building a Ring-inspired middleware library on top of
`Std.Http.Server` (the async HTTP server shipped in the Lean 4 toolchain itself,
under `Std.Http`). The full roadmap has six stages: core scaffolding, pure
request/response-shaping middleware, conditional-GET/static files, multipart
parsing, cookies/sessions, and hardening.

That's realistically weeks of work, and stages 4-5 have open design questions
(e.g. whether new generically-useful HTTP header types like `Set-Cookie`/`ETag`
belong upstream in `Std.Http` or in this repo — CLAUDE.md says to ask before
deciding that) that shouldn't be resolved by assumption. Per the user's
direction, this plan covers **Phase 1 (core scaffolding) and Phase 2 (the
first batch of Stage-1 middleware: params, content-type, content-length,
head)** in full, concrete detail. Later phases are noted at the end as the
roadmap, each requiring its own planning pass before implementation.

Key facts established during exploration (grounded against the toolchain
source, not memory):

- The repo's pinned toolchain (`leanprover/lean4:v4.33.0`) already contains
  `Std.Http.Server` — confirmed identical API to a locally-installed v4.31.0
  toolchain used for direct source inspection, with only a trivial namespace-
  qualification diff. **No `lakefile.toml` dependency/`require` entry is
  needed** — `Std` ships alongside `Init`/`Lean` in the toolchain's `LEAN_PATH`,
  the same way `Init` does.
- The core handler type is `StatelessHandler` (`Std.Http.Server.Handler`):
  `onRequest : Request Body.Stream → ContextAsync (Response Body.Any)`, plus
  `onFailure`/`onContinue`.
- `Std.Http.Internal.Test` (`Std/Http/Test/Helpers.lean`) is a `public`
  in-toolchain mock-connection test harness (`check`, `mkGet`, `mkPost`,
  `assertContains`, etc.) — we reuse it rather than building our own.
- `ContextAsync` has a `MonadExcept IO.Error` instance, so ordinary
  `try/catch` works for `catchAll`.
- `Response.Builder.text`/`.json`/`.html` (`Body/Full.lean`) build
  `Async (Response Body.Full)`, which coerces to `ContextAsync (Response Body.Any)`
  via existing `Coe` instances — this is how `catchAll` produces its 500 response.
- Query-string parsing already exists as `Std.Http.URI.Query` /
  `URI.EncodedQueryParam` (`ofString?`/`decode`/`encode`). The internal
  `parseQuery` combinator is `private`, so `params`'s form-urlencoded body
  parser reuses `EncodedQueryParam` for percent-decoding rather than
  reimplementing it, and only writes the small `key=value&key=value` splitting
  loop itself.

## Package layout

Replace the placeholder `Middleware/Basic.lean` (`def hello := "world"`) with
real modules, everything under a `Middleware` namespace:

```
Middleware.lean                 -- aggregator: imports every submodule below
Middleware/Core.lean             -- Middleware type + composition
Middleware/CatchAll.lean
Middleware/Params.lean
Middleware/ContentType.lean
Middleware/ContentLength.lean
Middleware/Head.lean
Tests.lean                       -- test-driver entrypoint (`lake test`)
Tests/Core.lean
Tests/CatchAll.lean
Tests/Params.lean
Tests/ContentType.lean
Tests/ContentLength.lean
Tests/Head.lean
```

`lakefile.toml` gains a test executable and driver:

```toml
testDriver = "tests"

[[lean_exe]]
name = "tests"
root = "Tests"
```

## Phase 1 — Core scaffolding

**`Middleware/Core.lean`**
```
abbrev Middleware := StatelessHandler → StatelessHandler

def Middleware.id : Middleware := id

/-- Applies middleware in outermost-to-innermost order: the first element of
`mws` is the outermost layer, closest to the client; the last is closest to
`base`. Requests pass through the list head-first; responses flow back tail-first. -/
def Middleware.apply (mws : List Middleware) (base : StatelessHandler) : StatelessHandler :=
  mws.foldr (· ·) base
```
Ordering is documented explicitly here since it's the thing that bites people
migrating from Ring's `->` threading macro (e.g. `session` must wrap `flash`
once we get to Phase 5's stage).

**`Middleware/CatchAll.lean`**
```
def catchAll (onError : IO.Error → Async Unit := fun _ => pure ()) : Middleware :=
  fun handler =>
    { handler with
      onRequest := fun req => do
        try
          handler.onRequest req
        catch e =>
          onError e
          pure (Response.internalServerError.text "Internal Server Error" : Response Body.Any) }
```
(Exact syntax to be nailed down against `lean_diagnostic_messages` during
implementation — the shape above is verified against `MonadExcept IO.Error
ContextAsync` and the `Response.Builder.text` → `Body.Any` coercion chain, but
I haven't hand-typechecked it.)

**Tests**: `Tests/Core.lean` builds a small stack of no-op marker middleware
(each appends a fixed response header) and asserts via
`Std.Http.Internal.Test.check`/`assertContains` that the header order in the
response matches the documented outermost-first semantics. `Tests/CatchAll.lean`
wraps a handler that throws and asserts a 500 comes back, plus a passthrough
case asserting a normal 200 response is untouched.

## Phase 2 — Stage 1 middleware

**`Middleware/Params.lean`**
```
structure Params where
  query : URI.Query := .empty
  form : URI.Query := .empty

namespace Params
def get (p : Params) (key : String) : Option String :=
  -- form overrides query on conflict, matching ring.middleware.params'
  -- (merge query-params form-params)
  (p.form.get key).orElse (fun _ => p.query.get key)
end Params
```
Middleware: drains the body only when `Content-Type` is
`application/x-www-form-urlencoded`, parses it with the same
`key=value&key=value` splitting logic backed by `EncodedQueryParam`, replaces
the request body with `Body.fromBytes` of the already-read bytes (so
downstream handlers/middleware can still read it), and inserts a `Params`
extension via `Extensions.insert`.

**`Middleware/ContentType.lean`**: if the response has no `Content-Type`
header, infer one from the request path's extension via a small
extension→MIME lookup table, defaulting to `application/octet-stream`.

**`Middleware/ContentLength.lean`**: if the response body's `getKnownSize`
reports a fixed size and no `Content-Length` header is set, set it.

**`Middleware/Head.lean`**: rewrites `HEAD` requests to `GET` before calling
the inner handler, then strips the response body (keeping headers) on the way
back out.

**Tests**: example-based tests per middleware against
`Std.Http.Internal.Test.check`, plus a Plausible property test in
`Tests/Params.lean` for the form-urlencoded parser: for arbitrary
`Array (String × String)` with printable-ASCII keys/values,
`parse (render pairs) = pairs` up to encoding-choice normalization — the
same roundtrip shape already used for `URI.Query` elsewhere in Std.Http.

## Verification

- After each file edit: `mcp__lean-lsp__lean_diagnostic_messages` (per
  CLAUDE.md; `lean_build` instead if imports change).
- `lake build` and `lake test` from the repo root as final ground truth,
  clean of warnings.

## Roadmap beyond this plan (not executed now)

- **Stage 2** — conditional GET / static files: `not-modified` (needs new
  `ETag`/`Last-Modified` header types — none exist in `Std.Http` yet),
  `file`/`file-info` (includes the `SafePath` proof-carrying subtype for
  path-traversal safety discussed earlier), `resource`.
- **Stage 3** — `multipart-params`, with a structural-recursion termination
  argument required by the project's no-`partial` rule.
- **Stage 4** — `cookies`/`session`/`flash`. **Blocked on a decision**: new
  `Set-Cookie`/`Cookie` header types are generically useful beyond this
  library, so per CLAUDE.md this needs to be raised with the user (upstream
  `Std.Http` vs. local to this repo) before writing them. Session-store laws
  (`LawfulSessionStore`) and HMAC-signed cookie stores also need checking
  against whatever crypto primitives Std actually exposes.
- **Stage 5** — full Plausible suite, integration tests per middleware,
  documented default composition order.

Each of these gets its own plan when we get there.
