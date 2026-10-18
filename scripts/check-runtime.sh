#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
#
# Nothing from the Lean package may reach a consumer's binary, `extract` included. This reads
# that claim off `test/LeanFree.lean`, an executable that uses the macro. Building it builds the
# library too, so everything examined below is this checkout's own output.
#
# The link line is not the place to look: Lake names `-lLean` for every executable it builds,
# and a library archive contributes only the members something referred to. What ended up in the
# binary is the answer.

set -euo pipefail

cd "$(dirname "$0")/.."

command -v nm >/dev/null || { echo "error: 'nm' is needed to read the binary's symbols" >&2; exit 1; }

(cd test && lake build leanFree >/dev/null)

exe=test/.lake/build/bin/leanFree
status=0

# `grep -c` rather than `grep -q`: `-q` stops at the first match and so kills the process feeding
# it, which under `pipefail` reads as "found nothing".
frontend_hits() { grep -c 'l_Lean_Elab\|initialize_Lean_' || true; }

# 1. No compiled module of the library starts a Lean module at run time. A `meta import` starts
#    one only from the meta initialiser, which runs during elaboration.
for c in .lake/build/ir/Middleware.c .lake/build/ir/Middleware/*.c; do
  [ -f "$c" ] || continue
  if [ "$(awk '/LEAN_EXPORT lean_object\* runtime_initialize_/,/^}/' "$c" | frontend_hits)" -ne 0 ]; then
    echo "error: $c starts a Lean module at run time, not only during elaboration" >&2
    status=1
  fi
done

# 2. The consumer's compiled module, holding what `extract` generated, refers to nothing from the
#    Lean package.
if [ "$(frontend_hits < test/.lake/build/ir/LeanFree.c)" -ne 0 ]; then
  echo "error: the consumer's compiled module refers to the Lean package" >&2
  status=1
fi

# 3. Neither does the executable those modules were linked into.
if [ "$(nm "$exe" | frontend_hits)" -ne 0 ]; then
  echo "error: $exe carries Lean frontend symbols" >&2
  status=1
fi

# 4. And it still extracts. A binary that cannot is a cheap way to pass 1-3.
expected='HTTP/1.1 200 OK / hello Countess Ada
HTTP/1.1 400 Bad Request / missing required parameter `name`'
actual=$("./$exe")
if [ "$actual" != "$expected" ]; then
  echo "error: $exe did not extract as expected; got:" >&2
  echo "$actual" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "ok: an executable using extract carries nothing from the Lean package ($(du -h "$exe" | cut -f1))"
fi
exit "$status"
