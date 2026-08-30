/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Server

public section

open Std.Http
open Std.Http.Internal.Char (fieldVchar fieldContent)

namespace Middleware.Header.Value

/-- SP and HTAB are `field-content`, but the grammar admits them only *between* two `field-vchar`s,
so a value can neither begin nor end with one. -/
private def isPadding (c : Char) : Bool :=
  !fieldVchar c

/-- Drops the trailing run of padding. Whatever survives keeps the head of the input, which is what
lets a leading trim be done independently. -/
private def trimEnd : List Char → List Char
  | [] => []
  | c :: cs =>
    let rest := trimEnd cs
    if rest.isEmpty && isPadding c then [] else c :: rest

private def sanitized (s : String) : List Char :=
  trimEnd ((s.toList.filter fieldContent).dropWhile isPadding)

/--
Discarding a prefix never conjures a character that wasn't already there. `sanitized` establishes
"every character is `field-content`" on the filtered list and only then drops the leading padding,
so that conjunct survives the drop only because of this.

For any predicate `p`, any list `l` and any character `c`: if `c` is in `l.dropWhile p`, the list
`l` with its longest `p`-satisfying prefix removed, then `c` is in `l`. The hypothesis is not
vacuous, since `dropWhile` returns `l` unchanged whenever `p` is false at the head.
-/
private theorem mem_of_mem_dropWhile {p : Char → Bool} :
    ∀ {l : List Char} {c : Char}, c ∈ l.dropWhile p → c ∈ l
  | [], _, h => by simp at h
  | x :: xs, c, h => by
    cases hx : p x with
    | true =>
      rw [List.dropWhile_cons_of_pos hx] at h
      exact List.mem_cons_of_mem _ (mem_of_mem_dropWhile h)
    | false =>
      rw [List.dropWhile_cons_of_neg (by simp [hx])] at h
      exact h

/--
The same for the trailing trim: `trimEnd` only ever removes characters. Together with
`mem_of_mem_dropWhile` this is what carries `field-content`-ness from the filter, which is the
only step that establishes it, out to the fully sanitized list.

For any list `l` and character `c`: if `c` is in `trimEnd l`, the list with its trailing run of
padding removed, then `c` is in `l`. Not vacuous, since `trimEnd` is the identity on any list
whose last character is not padding.
-/
private theorem mem_of_mem_trimEnd :
    ∀ {l : List Char} {c : Char}, c ∈ trimEnd l → c ∈ l
  | [], _, h => by simp [trimEnd] at h
  | x :: xs, c, h => by
    simp only [trimEnd] at h
    split at h
    · simp at h
    · rcases List.mem_cons.mp h with h | h
      · exact h ▸ List.mem_cons_self ..
      · exact List.mem_cons_of_mem _ (mem_of_mem_trimEnd h)

/--
Whatever `dropWhile` leaves at the front fails the predicate it was dropping on. This is what
gives the sanitized value a first character that is a `field-vchar`, and so satisfies the second
of `IsValidHeaderValue`'s three conjuncts.

For any predicate `p`, list `l` and character `c`: if `c` is the head of `l.dropWhile p`, then
`p c` is `false`, meaning `c` was the first element `dropWhile` declined to drop. Not vacuous:
`head? = some c` holds exactly when the dropped-through list is non-empty, which it is for any
input carrying a `field-vchar`.
-/
private theorem head?_dropWhile {p : Char → Bool} :
    ∀ {l : List Char} {c : Char}, (l.dropWhile p).head? = some c → p c = false
  | [], _, h => by simp at h
  | x :: xs, c, h => by
    cases hx : p x with
    | true =>
      rw [List.dropWhile_cons_of_pos hx] at h
      exact head?_dropWhile h
    | false =>
      rw [List.dropWhile_cons_of_neg (by simp [hx])] at h
      simp at h
      exact h ▸ hx

/--
Trimming the end never changes the front. This is what lets the leading and trailing trims be
reasoned about separately: `head?_dropWhile` speaks about the list before `trimEnd` runs, and
this carries its conclusion to the list after.

For any list `l` and character `c`: if `c` is the head of `trimEnd l`, then `c` is also the head
of `l` itself. Not vacuous, since `trimEnd` returns a non-empty list for every input containing a
non-padding character.
-/
private theorem head?_trimEnd {l : List Char} {c : Char}
    (h : (trimEnd l).head? = some c) : l.head? = some c := by
  match l with
  | [] => simp [trimEnd] at h
  | x :: xs =>
    simp only [trimEnd] at h
    split at h
    · simp at h
    · simpa using h

/--
Whatever `trimEnd` leaves at the end is not padding. That is the point of the function, and it
supplies the third of `IsValidHeaderValue`'s conjuncts, the one forbidding a value that ends in a
space or a tab.

For any list `l` and character `c`: if `c` is the last element of `trimEnd l`, then `isPadding c`
is `false`, i.e. `c` is a `field-vchar`. Not vacuous, since `getLast? = some c` holds exactly
when the trimmed list is non-empty.
-/
private theorem getLast?_trimEnd :
    ∀ {l : List Char} {c : Char}, (trimEnd l).getLast? = some c → isPadding c = false
  | [], _, h => by simp [trimEnd] at h
  | x :: xs, c, h => by
    simp only [trimEnd] at h
    split at h
    · simp at h
    · rename_i hcond
      match hx : trimEnd xs with
      | [] =>
        rw [hx] at h
        simp at h
        simp [hx] at hcond
        exact h ▸ hcond
      | y :: ys =>
        rw [hx, List.getLast?_cons_cons] at h
        exact getLast?_trimEnd (hx ▸ h)

/--
Every string whatsoever sanitizes to something HTTP accepts as a field value. This is what makes
`ofStringSanitized` total: it can hand `Header.Value` a proof for arbitrary application-supplied
text, so no caller needs a fallback for text it cannot vet, and no such text can smuggle a CR or
LF into the header block.

For any string `s`, `IsValidHeaderValue (String.ofList (sanitized s))` holds, which unfolds to
three conjuncts about the sanitized character list: every character answers `true` to
`Char.fieldContent`; its head, if it has one, answers `true` to `Char.fieldVchar`; and its last
character, if it has one, does too. The two positional conjuncts are stated over `Option`, so an
input that filters away to nothing satisfies them vacuously, which is correct rather than a gap:
the empty string is a valid header value.
-/
private theorem valid_sanitized (s : String) :
    Std.Http.Header.IsValidHeaderValue (String.ofList (sanitized s)) := by
  refine ⟨?_, ?_, ?_⟩ <;> simp only [String.toList_ofList]
  · refine List.all_eq_true.mpr fun c hc => ?_
    exact (List.mem_filter.mp (mem_of_mem_dropWhile (mem_of_mem_trimEnd hc))).2
  · cases h : (sanitized s).head? with
    | none => simp
    | some c =>
      have := head?_dropWhile (head?_trimEnd h)
      simp only [isPadding, Bool.not_eq_false'] at this
      simp [this]
  · cases h : (sanitized s).getLast? with
    | none => simp
    | some c =>
      have := getLast?_trimEnd h
      simp only [isPadding, Bool.not_eq_false'] at this
      simp [this]

/--
Builds a `Header.Value` from an arbitrary string by discarding every character HTTP doesn't permit
in a field value and trimming the ends, rather than rejecting the string. Total, so a caller
holding application-supplied text needs neither a fallback nor a proof; and since CR and LF are
among the discarded characters, such text can't inject headers of its own either.
-/
def ofStringSanitized (s : String) : Std.Http.Header.Value :=
  ⟨String.ofList (sanitized s), valid_sanitized s⟩

end Middleware.Header.Value
