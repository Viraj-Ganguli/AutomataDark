import Spec

/-!
# Fast feed plan (written by the coder agent)

Storage order is chronological, so the feed is just the last 20 rows,
reversed: no sort. That is only right while the invariant holds, so the
product checks it at startup (`checkInv`) and on every insert (`insertOk`),
and falls back to the model's query when either says no.
-/

namespace Impl
open Spec

def feedPlan (db : Db) : List Post := db.posts.reverse.take feedSize

def increasingCheck : List Post → Bool
  | a :: b :: rest => decide (a.createdAt < b.createdAt) && increasingCheck (b :: rest)
  | _ => true

def checkInv (db : Db) : Bool := increasingCheck db.posts

def insertOk (db : Db) (p : Post) : Bool :=
  match db.posts.getLast? with
  | none => true
  | some q => decide (q.createdAt < p.createdAt)

theorem increasingCheck_sound : (l : List Post) → increasingCheck l = true → Increasing l
  | [], _ => by simp [Increasing]
  | [_], _ => by simp [Increasing]
  | a :: b :: rest, h => by
    simp only [increasingCheck, Bool.and_eq_true, decide_eq_true_eq] at h
    exact ⟨h.1, increasingCheck_sound (b :: rest) h.2⟩

theorem checkInv_sound : CheckSound checkInv := fun _ h => increasingCheck_sound _ h

theorem increasing_append : (l : List Post) → (p : Post) → Increasing l →
    (∀ q, l.getLast? = some q → q.createdAt < p.createdAt) → Increasing (l ++ [p])
  | [], _, _, _ => by simp [Increasing]
  | [a], p, _, h => by
    have := h a rfl
    simp [Increasing, this]
  | a :: b :: rest, p, ⟨hab, hr⟩, h => by
    have ih := increasing_append (b :: rest) p hr (fun q hq => h q (by simpa using hq))
    exact ⟨hab, ih⟩

theorem insertOk_preserves : InsertPreserves insertOk := by
  intro db p hinv hok
  apply increasing_append db.posts p hinv
  intro q hq
  simp only [insertOk, hq, decide_eq_true_eq] at hok
  exact hok

theorem head_lt : (a : Post) → (l : List Post) → Increasing (a :: l) →
    ∀ q ∈ l, a.createdAt < q.createdAt
  | _, [], _, q, hq => by simp at hq
  | a, b :: rest, ⟨hab, hr⟩, q, hq => by
    rcases List.mem_cons.mp hq with rfl | hq
    · exact hab
    · exact Nat.lt_trans hab (head_lt b rest hr q hq)

theorem increasing_tail : {a : Post} → {l : List Post} → Increasing (a :: l) → Increasing l
  | _, [], _ => by simp [Increasing]
  | _, _ :: _, ⟨_, hr⟩ => hr

theorem insertNewest_oldest (p : Post) : (l : List Post) →
    (∀ q ∈ l, p.createdAt < q.createdAt) → insertNewest p l = l ++ [p]
  | [], _ => rfl
  | q :: qs, h => by
    have hq := h q (by simp)
    have hn : ¬ q.createdAt < p.createdAt := Nat.lt_asymm hq
    have ih := insertNewest_oldest p qs (fun r hr => h r (by simp [hr]))
    simp [insertNewest, hn, ih]

theorem newestFirst_eq_reverse : (l : List Post) → Increasing l → newestFirst l = l.reverse
  | [], _ => rfl
  | a :: l, h => by
    rw [newestFirst, newestFirst_eq_reverse l (increasing_tail h),
      insertNewest_oldest a l.reverse (fun q hq => head_lt a l h q (List.mem_reverse.mp hq))]
    simp

theorem feedPlan_correct : PlanCorrect feedPlan := by
  intro db h
  simp [feedPlan, feed, newestFirst_eq_reverse _ h]

end Impl
