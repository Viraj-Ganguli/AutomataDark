import Spec.Model

/-!
# Proof obligations (protected, human-approved)

Each obligation is a predicate on an implementation the coder agent supplies.
`Spec/obligations.json` names which implementation constant each one is about
and which theorem must prove it; `factory` checks the theorem's statement is
exactly `Predicate impl`, so it can't be weakened.
-/

namespace Spec

/-- The fast plan returns exactly the model's feed whenever the invariant holds. -/
def PlanCorrect (plan : Db → List Post) : Prop := ∀ db, Inv db → plan db = feed db

/-- The runtime check (run at startup) only says yes when the invariant holds. -/
def CheckSound (check : Db → Bool) : Prop := ∀ db, check db = true → Inv db

/-- The per-insert check keeps the invariant: if it says yes, the fast plan
stays valid after the insert; if it says no, the product falls back to the model. -/
def InsertPreserves (ok : Db → Post → Bool) : Prop :=
  ∀ db p, Inv db → ok db p = true → Inv (addPost db p)

end Spec
