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

private theorem head?_trimEnd {l : List Char} {c : Char}
    (h : (trimEnd l).head? = some c) : l.head? = some c := by
  match l with
  | [] => simp [trimEnd] at h
  | x :: xs =>
    simp only [trimEnd] at h
    split at h
    · simp at h
    · simpa using h

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
