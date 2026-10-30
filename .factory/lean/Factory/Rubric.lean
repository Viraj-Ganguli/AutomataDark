/-!
# Rubric scorer (`factory score`)

The weighted rubric score, in exact arithmetic. The spec is

  overall = Σ_d weight_d · (Σ scores in d) / n_d,   pass ⟺ overall ≥ threshold

with weights summing to 1. `factory score` reads the decimal weights and the
threshold from `rubric.json` exactly (JSON numbers are decimals, so
`0.35 = 35/100`), with no floating point. Weights become `Nat` numerators
over a common denominator `W`, the threshold becomes `tn / tden`, and
everything is multiplied by a common multiple `D` of the criteria counts:

  scaled = Σ_d w_d · S_d · (D / n_d) = overall · W · D,
  pass   ⟺ tn · W · D ≤ tden · scaled.

`pass` and `scaled` below are the functions `factory score` runs.

The review output is written by an agent, so scores are arbitrary `Int`s and
`sanitize` mirrors the scorer's rule: a score outside [0, 100] counts as 0.

The main results:

* `scaled_le`: for *any* review output, `overall ≤ 100 · Σ weight / 100`.
  So a forged score can't push the result past a perfect review.
* `scaled_mono`: raising any score never lowers the result.
* `lone_criterion_fails` / `forged_score_fails`: on the current rubric, no
  single criterion can make a review pass, even with a bogus value.
* `unsanitized_forgery_passes`: without the validity filter (the old scorer),
  one score of 10^6 passes.
* `two_security_zeros_pass`: a design finding, not a bug. The rubric passes a
  review that scores 0 on two of the four security criteria.
-/

namespace Factory.Rubric

structure Dim where
  /-- Numerator over the rubric's common weight denominator `W`. -/
  weight : Nat
  /-- Number of criteria in the dimension. -/
  n : Nat
  deriving Repr

/-- The scorer's validity filter. -/
def sanitize (s : Int) : Nat := if 0 ≤ s ∧ s ≤ 100 then s.toNat else 0

def dimSum (ss : List Int) : Nat := (ss.map sanitize).sum

def scaled (D : Nat) : List Dim → List (List Int) → Nat
  | d :: ds, ss :: sss => d.weight * dimSum ss * (D / d.n) + scaled D ds sss
  | _, _ => 0

def totalWeight : List Dim → Nat
  | [] => 0
  | d :: ds => d.weight + totalWeight ds

/-- `overall ≥ tn / tden`, with weights over `W`, cross-multiplied by `tden · W · D`. -/
def pass (tn tden W D : Nat) (dims : List Dim) (scores : List (List Int)) : Bool :=
  decide (tn * W * D ≤ tden * scaled D dims scores)

/-- One score list per dimension, with one score per criterion. -/
def Shaped : List Dim → List (List Int) → Prop
  | [], [] => True
  | d :: ds, ss :: sss => ss.length = d.n ∧ Shaped ds sss
  | _, _ => False

theorem sanitize_le (s : Int) : sanitize s ≤ 100 := by
  unfold sanitize; split <;> omega

theorem dimSum_le (ss : List Int) : dimSum ss ≤ 100 * ss.length := by
  induction ss with
  | nil => simp [dimSum]
  | cons s ss ih =>
    simp only [dimSum, List.map_cons, List.sum_cons, List.length_cons] at ih ⊢
    have := sanitize_le s
    omega

/-- No review output, however malformed, scores above a perfect review. -/
theorem scaled_le (D : Nat) :
    ∀ (dims : List Dim) (scores : List (List Int)),
      Shaped dims scores → (∀ d ∈ dims, d.n ∣ D) →
      scaled D dims scores ≤ 100 * D * totalWeight dims
  | [], [], _, _ => by simp [scaled, totalWeight]
  | d :: ds, ss :: sss, ⟨hlen, hs⟩, hdvd => by
    have ih := scaled_le D ds sss hs (fun d' h => hdvd d' (List.mem_cons_of_mem _ h))
    have hd : d.n * (D / d.n) = D := Nat.mul_div_cancel' (hdvd d (List.mem_cons_self ..))
    have hsum := dimSum_le ss
    rw [hlen] at hsum
    have term : d.weight * dimSum ss * (D / d.n) ≤ 100 * D * d.weight := by
      calc d.weight * dimSum ss * (D / d.n)
          ≤ d.weight * (100 * d.n) * (D / d.n) :=
            Nat.mul_le_mul_right _ (Nat.mul_le_mul_left _ hsum)
        _ = 100 * (d.n * (D / d.n)) * d.weight := by
            simp only [Nat.mul_comm, Nat.mul_assoc, Nat.mul_left_comm]
        _ = 100 * D * d.weight := by rw [hd]
    simp only [scaled, totalWeight]
    rw [Nat.mul_add]
    omega
  | [], _ :: _, h, _ | _ :: _, [], h, _ => by simp [Shaped] at h

/-- With weights summing to 1 (`totalWeight = W`), `overall ≤ 100`. -/
theorem overall_le_100 {W D : Nat} {dims : List Dim} {scores : List (List Int)}
    (hs : Shaped dims scores) (hdvd : ∀ d ∈ dims, d.n ∣ D) (hw : totalWeight dims = W) :
    scaled D dims scores ≤ 100 * W * D := by
  have := scaled_le D dims scores hs hdvd
  rw [hw] at this
  simpa [Nat.mul_comm, Nat.mul_left_comm] using this

/-- So a threshold above 100 can never pass, whatever the review says. -/
theorem threshold_above_100_never_passes {tn tden W D : Nat} {dims : List Dim}
    {scores : List (List Int)} (hs : Shaped dims scores) (hdvd : ∀ d ∈ dims, d.n ∣ D)
    (hw : totalWeight dims = W) (hpos : 0 < W * D) (ht : 100 * tden < tn) :
    pass tn tden W D dims scores = false := by
  have hle := overall_le_100 hs hdvd hw
  simp only [pass, decide_eq_false_iff_not, Nat.not_le]
  have h1 : tden * scaled D dims scores ≤ tden * (100 * W * D) := Nat.mul_le_mul_left _ hle
  have h2 : tden * (100 * W * D) < tn * (W * D) := by
    rw [show tden * (100 * W * D) = (100 * tden) * (W * D) by
      simp only [Nat.mul_comm, Nat.mul_left_comm, Nat.mul_assoc]]
    exact Nat.mul_lt_mul_of_pos_right ht hpos
  rw [Nat.mul_assoc tn]
  omega

/-- Pointwise order on one dimension's scores, after `sanitize`. -/
def LeList : List Int → List Int → Prop
  | [], [] => True
  | x :: xs, y :: ys => sanitize x ≤ sanitize y ∧ LeList xs ys
  | _, _ => False

/-- Pointwise order on review outputs. -/
def LeScores : List (List Int) → List (List Int) → Prop
  | [], [] => True
  | a :: as, b :: bs => LeList a b ∧ LeScores as bs
  | _, _ => False

theorem dimSum_mono : ∀ {a b : List Int}, LeList a b → dimSum a ≤ dimSum b
  | [], [], _ => Nat.le_refl _
  | _ :: _, _ :: _, ⟨hxy, hrest⟩ => by
    have := dimSum_mono hrest
    simp only [dimSum, List.map_cons, List.sum_cons] at this ⊢
    omega
  | [], _ :: _, h | _ :: _, [], h => by simp [LeList] at h

/-- Raising any criterion's (valid) score never lowers the overall score. -/
theorem scaled_mono (D : Nat) :
    ∀ (dims : List Dim) (a b : List (List Int)), LeScores a b →
      scaled D dims a ≤ scaled D dims b
  | [], _, _, _ => by simp [scaled]
  | _ :: _, [], [], _ => by simp [scaled]
  | d :: ds, sa :: as, sb :: bs, ⟨h1, h2⟩ => by
    have ih := scaled_mono D ds as bs h2
    have := Nat.mul_le_mul_right (D / d.n) (Nat.mul_le_mul_left d.weight (dimSum_mono h1))
    simp only [scaled]
    omega
  | _ :: _, [], _ :: _, h | _ :: _, _ :: _, [], h => by simp [LeScores] at h

/-! ## The current rubric (`.factory/rubric.json`)

`factory check-rubric` (run by `scripts/run-all.sh`) checks that the JSON file
has this shape, so these theorems describe the real config. -/

def current : List Dim := [⟨40, 4⟩, ⟨35, 5⟩, ⟨25, 3⟩]   -- security, architecture, style
def threshold : Nat := 75
def W : Nat := 100
def D : Nat := 60

theorem current_wellformed : totalWeight current = W ∧ ∀ d ∈ current, d.n ∣ D := by
  decide

def passCurrent (scores : List (List Int)) : Bool := pass threshold 1 W D current scores

/-- Security criteria carry the most weight each (40%/4 = 10 points). Even
those, alone and with any value, can't pass a review. -/
theorem lone_criterion_fails (s : Int) :
    passCurrent [[s, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0]] = false := by
  have := sanitize_le s
  simp [passCurrent, pass, scaled, dimSum, sanitize, current, threshold, W, D] at *
  omega

theorem forged_score_fails :
    passCurrent [[1000000, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0]] = false :=
  lone_criterion_fails _

/-- The pre-fix scorer: any finite number was accepted as a score. -/
def scaledUnsanitized (D : Nat) : List Dim → List (List Int) → Int
  | d :: ds, ss :: sss => d.weight * ss.sum * (D / d.n : Nat) + scaledUnsanitized D ds sss
  | _, _ => 0

theorem unsanitized_forgery_passes :
    (threshold * W * D : Int) ≤
      scaledUnsanitized D current [[1000000, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0]] := by
  decide

/-- Rubric design finding: zero on two of four security criteria still passes. -/
theorem two_security_zeros_pass :
    passCurrent [[100, 50, 0, 0], [100, 100, 100, 100, 100], [100, 100, 100]] = true := by
  decide

end Factory.Rubric
