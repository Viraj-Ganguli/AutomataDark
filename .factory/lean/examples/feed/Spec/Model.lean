/-!
# Feed model (protected, human-approved)

The meaning of `GET /feed`, written to be obviously right rather than fast:
sort every post newest-first, then take 20. This is the spec the fast plan in
`Impl/` must match, and the oracle for differential tests of the product.
-/

namespace Spec

structure Post where
  id : Nat
  author : String
  createdAt : Nat
  deriving Repr, DecidableEq, Inhabited

/-- Posts in storage (rowid) order. -/
structure Db where
  posts : List Post
  deriving Repr

/-- Insert into a newest-first list. -/
def insertNewest (p : Post) : List Post → List Post
  | [] => [p]
  | q :: qs => if q.createdAt < p.createdAt then p :: q :: qs else q :: insertNewest p qs

/-- Insertion sort, newest first. -/
def newestFirst : List Post → List Post
  | [] => []
  | p :: ps => insertNewest p (newestFirst ps)

def feedSize : Nat := 20

/-- `GET /feed`: the 20 newest posts, newest first. -/
def feed (db : Db) : List Post := (newestFirst db.posts).take feedSize

/-- `POST /posts` appends a row. -/
def addPost (db : Db) (p : Post) : Db := { db with posts := db.posts ++ [p] }

/-- Storage order is strictly increasing in `createdAt`. -/
def Increasing : List Post → Prop
  | [] => True
  | [_] => True
  | a :: b :: rest => a.createdAt < b.createdAt ∧ Increasing (b :: rest)

/-- The data invariant a fast plan may rely on. -/
def Inv (db : Db) : Prop := Increasing db.posts

end Spec
