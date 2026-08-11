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

---

# Stage 2: conditional GET (`notModified`) and static file serving (`file`)

## Status: implemented

`lake build` and `lake test` pass clean from a from-scratch rebuild, no
warnings. Delivered as designed: `Middleware/NotModified.lean` (`ETag`,
`LastModified`, `IfNoneMatch`, `IfModifiedSince` header types + `notModified`
middleware) and `Middleware/File.lean` (`isSafeSegment`/`joinSafeSegments` +
the `joinSafeSegments_eq` safety theorem, `resolvePath`, `streamFile`,
`isContainedIn`, `file` middleware). The theorem landed close to the planned
shape and was fully discharged (no `sorry`) using
`Array.all_eq_true_iff_forall_mem` from core — no bespoke induction needed.

Bugs caught only by the tests, worth remembering:
- **Monadic `||`/`&&` don't short-circuit `←`-binds.** `file`'s first cut
  wrote `if (← path.isDir) || !(← path.pathExists) || !(← isContainedIn root
  path) then ...` intending pathExists-first short-circuit logic; in `do`
  notation every `←` inside a boolean expression runs unconditionally before
  the `||`/`&&` combine the results, so `isContainedIn` (which calls
  `IO.FS.realPath`, throwing on a nonexistent path) ran even for missing
  files and turned a should-be-404-fallthrough into a 500. Fixed by
  sequential `if !(← pathExists) then ... else if (← isDir) then ... else if
  !(← isContainedIn) then ... else ...` so each `←` only runs once prior
  checks have passed. Watch for this pattern anywhere else a boolean
  combinator wraps more than one `←`.
- Response header names render in `Name.toCanonical` form (title-case per
  hyphen-separated word, e.g. `Etag` not `ETag`, `Last-Modified` as written)
  — same lesson as `X-Order`/`x-order` from Phase 1, worth remembering as a
  standing gotcha for any test asserting on raw header text rather than
  parsing it back through the typed `Header` API.
- `Second.Offset`/`Timestamp`/`DateTime` construction from a raw
  `IO.FS.Metadata.modified : SystemTime` epoch-seconds value goes through
  `Std.Time.Second.Offset.ofNat` → `Timestamp.ofSecondsSinceUnixEpoch` →
  `DateTime.ofTimestampWithZone (_) Std.Time.TimeZone.UTC` — no direct
  `SystemTime → DateTime` conversion exists.
- `meta` is a reserved keyword in this Lean version (collides with
  metaprogramming syntax) — can't be used as a local/parameter name, unlike
  in most other languages' HTTP-library code. Renamed to `md` throughout.
  `matches` is also reserved; renamed `IfNoneMatch.matches` to `matchesTag`.

Not attempted this pass (unchanged from the plan): `resource`, `Range`
support, `Cache-Control`/`Vary`/`Expires` preservation on `304`s.

## Context

Following on from Phase 1/2 (core scaffolding, `catchAll`, `contentType`,
`params` — implemented, see `PLAN.md` in the repo root for that history),
this covers Stage 2 of the middleware roadmap: a generic conditional-GET
middleware and a directory-backed static-file middleware. `file-info` is
folded into `file` (it sets its own Last-Modified/ETag; `notModified` does
the generic 304 short-circuiting, so a separate middleware would just
duplicate that). `resource` (Ring's classpath-resource equivalent) is
deferred to its own pass — there's no clean Lean analogue and no concrete
use case yet to design against, per the user's explicit scope choice.

This is the highest-stakes pass so far: `file` serves arbitrary filesystem
paths driven by client-controlled URLs, so path-traversal safety is the
central design concern, not an afterthought. It's also the pass where the
"theorems worth proving" discussion from earlier becomes concrete — the
path-safety resolver is exactly the kind of thing worth backing with a proof
rather than an ad hoc runtime check, per that earlier conversation and per
CLAUDE.md's security-review instincts.

Research findings (grounded against `/home/vscode/.elan/toolchains/leanprover--lean4---v4.33.0/src/lean`,
matching this repo's pinned toolchain exactly):

- **No conditional-GET header types exist.** `Std/Http/Data/Headers/Name.lean`
  has exactly 11 constants (`contentType`, `contentLength`, `host`,
  `authorization`, `userAgent`, `accept`, `connection`, `transferEncoding`,
  `server`, `date`, `expect`) — no `etag`/`if-none-match`/`last-modified`/
  `if-modified-since`. These need to be built in `Middleware/`, following the
  `Header` typeclass pattern already used for `ContentLength`/`Connection`/
  `Host` in `Std/Http/Data/Headers/Basic.lean`. Since `Std.Http` ships inside
  the Lean toolchain itself (not a `lake`-managed dependency we could vendor
  or patch), there's no practical "commit this to the dependency instead"
  option here the way CLAUDE.md's library-placement question usually implies
  — building them locally is the only real choice, not a judgment call.
- **`Std.Http.Internal.Char.etagc`** (`Std/Http/Internal/Char.lean:150-154`)
  is a dead-code ETag character-class validator (`'!' or '#'..'~'`), defined
  but never referenced anywhere — exactly what's needed to validate an ETag's
  opaque-tag content, first real use of it.
- **HTTP-date parsing exists and is unused so far.** `Std.Time.DateTime`
  (`Std/Time/Format.lean`) has `fromRFC822String : String → Except String
  DateTime` (line 368) alongside the `toRFC822String` already used for the
  `Date` response header in `Std/Http/Server/Connection.lean:176-177`. There's
  also a lenient `DateTime.parse` (line 429) that additionally tries RFC 850
  and asctime forms — worth using for `If-Modified-Since` since real clients
  still occasionally send the obsolete formats (RFC 9110 §5.6.7 requires
  servers to accept all three for compatibility, only requiring RFC 822/1123
  on the way out). Comparison goes through `DateTime.toTimestamp` /
  `Timestamp`. No consumer of the parse direction exists yet anywhere in
  `Std.Http` — exact `Timestamp` ordering API to be confirmed against
  `lean-lsp` during implementation rather than guessed here.
- **No hash function anywhere in `Std`/`Init`** (checked `sha1|sha256|md5|crc32|hmac`,
  zero hits). ETags here will be the standard weak-validator fallback used by
  most static file servers when no content hash is available: `W/"<hex
  mtime>-<hex size>"` from filesystem metadata, not a content hash. This is
  spec-legal (RFC 9110 §8.8.1 allows any implementation-chosen opaque tag) and
  matches what nginx/most static-file Ring middleware actually do.
- **File I/O is synchronous only** (`Init/System/IO.lean`); `Std/Async` has no
  `IO.FS` wrapper at all. `IO.FS.Handle.read (bytes : USize) : IO ByteArray`
  (line 847) is the chunked primitive — reads up to N bytes, empty result
  means EOF, doesn't close the handle. Existing `Std/Async/Basic.lean`
  `MonadLift (EIO ε) (EAsync ε)`/`MonadLift BaseIO (EAsync ε)` instances (lines
  708, 746, 749) should let plain `IO`/`BaseIO` calls (`handle.read`,
  `path.metadata`, `path.pathExists`) lift into `Async`/`ContextAsync` via
  ordinary `←` — to be confirmed empirically, same as other monad-lift
  questions in Phase 1/2.
- `Status.notModified` (304), `.partialContent` (206), `.rangeNotSatisfiable`
  (416) all already exist in `Std/Http/Data/Status.lean` — only 304 is used
  this pass (no Range support yet, that's future scope, not needed for a
  correct `not-modified`/`file` implementation).
- `Body.stream (gen : Stream → Async Unit) : Async Stream`
  (`Std/Http/Data/Body/Stream.lean:573`) is the existing combinator for
  building a chunked response body from a producer — the file-reading loop
  runs inside `gen`, one `handle.read`+`s.send` per chunk, so large files are
  never buffered whole. **This loop needs `partial def`.** Std.Http's own
  `Body.Stream.readAll`/`forIn`/`forIn'` (same file, "read until the channel
  closes") are themselves marked `partial` — there's no structurally
  decreasing argument for a "read until EOF" loop, so introducing a fuel
  parameter just to avoid `partial` would be worse practice than admitting it.
  Treating this as the one place in Stage 2 where CLAUDE.md's "absolutely
  essential" bar for `partial` is met, matching the toolchain's own precedent.

## Design

### `Middleware/NotModified.lean`

New header types (`Header` instances, mirroring `ContentLength`'s pattern):
- `ETag { value : String, weak : Bool }` — parse/serialize `"..."` /
  `W/"..."`, validating `value`'s characters against `etagc`.
- `LastModified { date : Std.Time.DateTime }` — via `fromRFC822String`/
  `toRFC822String`.
- `IfNoneMatch` — `| any | tags (List ETag)`; `*` or a comma-separated list.
  Weak comparison per RFC 9110 §8.8.3.2 (If-None-Match always uses weak
  comparison): two ETags match iff `value` is equal, ignoring the weak flag.
- `IfModifiedSince { date : Std.Time.DateTime }` — via the lenient
  `DateTime.parse`.

`notModified : Middleware` — post-processing only (no pre-step): runs the
inner handler, then checks the *response*'s `ETag`/`Last-Modified` headers
(if the handler/`file` set any) against the *request*'s `If-None-Match`/
`If-Modified-Since`. If-None-Match takes precedence when both are present
(RFC 9110 §13.1.1). On a match, downgrades to `304 Not Modified` with an
empty body, keeping only the `ETag`/`Last-Modified` headers from the original
response (documented as a deliberate simplification — a fully spec-precise
304 would also preserve `Cache-Control`/`Vary`/`Expires`, which this library
doesn't have middleware for yet). On no match, passes the response through
unchanged.

### `Middleware/File.lean`

**The safety-critical core, proved rather than merely tested:**

```
def IsSafeSegment (s : String) : Prop :=
  s ≠ "" ∧ s ≠ "." ∧ s ≠ ".." ∧ ∀ c ∈ s.toList, c ≠ '/' ∧ c ≠ '\x00'

def joinSafeSegments (segments : Array String) : Option String := ...
  -- `some (intercalate "/" segments)` iff every segment satisfies
  -- `IsSafeSegment`, else `none`

theorem joinSafeSegments_no_traversal ... :
  joinSafeSegments segments = some result →
    ¬ (result.splitOn "/").contains ".." ∧ ¬ (result.splitOn "/").contains "."
```

This works on **decoded path segments as plain strings**, not on
`Std.Http.URI.Path.normalize`. That's a deliberate choice, not an oversight:
`Path.normalize`'s dot-segment collapsing (`Std/Http/Data/URI/Basic.lean`)
compares each segment's *wire* (percent-encoded) form against the literal
strings `"."`/`".."` — a client sending the percent-encoded form (`%2e%2e`)
would sail through untouched, then decode to a literal `..` later when
building the filesystem path, reopening the exact hole `normalize` looked
like it was closing. Operating on `URI.Path.toDecodedSegments` (already
decoded) and rejecting `/`/NUL inside a decoded segment closes the adjacent
"encoded slash" variant of the same problem, where a segment decodes to
something containing an embedded separator and manufactures extra path
components that never existed at the URI-segment level.

The theorem statement and proof will be finalized interactively against
`lean_goal`/`lean_multi_attempt` during implementation, not fully
pre-derived here; the shape above (guard implies no `.`/`..` component in the
joined, split-and-rejoined result) is the target.

Everything after this point is a thin, ordinary (non-proved) layer:
- `resolvePath (root : System.FilePath) (uriPath : URI.Path) : Option System.FilePath`
  — `joinSafeSegments` + `root / rel`, plus (defense in depth, IO-time, not
  proved) a `System.FilePath.realPath` check that the resolved path's real
  path still has `root`'s real path as a prefix, catching symlink escapes
  inside the served directory that the pure segment check can't see.
- `streamFile (path) (chunkSize := 65536) : Async Body.Stream` — the
  `partial` read loop discussed above, backed by `Body.stream`.
- `file (root : System.FilePath) : Middleware` — on each request: resolve
  the path; if it doesn't resolve, doesn't exist, or is a directory, **fall
  through to the inner handler** (matching Ring's `wrap-file` semantics —
  this middleware doesn't own 404 handling, the base handler / rest of the
  chain does); otherwise stream the file with `Last-Modified` and a weak
  `ETag` set from its metadata. Deliberately does **not** set `Content-Type`
  itself — composing `contentType` outside it (`[contentType, notModified,
  file root]`) reuses the existing extension-lookup table
  (`Middleware.ContentType.extensionOf`/`lookup`) instead of duplicating it.

## Verification

- Same per-file loop as Phase 1/2: `mcp__lean-lsp__lean_diagnostic_messages`
  after each edit (`lean_build` when imports change), interactive proof work
  via `lean_goal`/`lean_multi_attempt` for the safety theorem.
- `Tests/NotModified.lean`: ETag match → 304; ETag mismatch → 200 passthrough;
  If-Modified-Since before/after Last-Modified; If-None-Match takes
  precedence over If-Modified-Since when both present.
- `Tests/File.lean`: writes real fixture files under a scratch temp directory
  at test-run time (not checked into the repo); serves and checks content +
  headers; missing file falls through to a stub inner handler; **a request
  path containing `../` (and its percent-encoded form `%2e%2e`) is rejected
  and falls through rather than serving anything outside the served root** —
  this is the concrete regression test paired with the proof.
- A Plausible property test for `joinSafeSegments`: arrays of generated safe
  (alphanumeric) segments always roundtrip through `intercalate`/`splitOn`;
  any array containing a literal `".."` element is always rejected.
- `lake build` and `lake test` clean from the repo root, no warnings, as
  final ground truth.
