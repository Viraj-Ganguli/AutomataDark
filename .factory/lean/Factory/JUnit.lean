import Factory.Red

/-!
# JUnit XML reader (for `factory red`)

JUnit XML is the one test-report format nearly every runner can write. This is
a small tag scanner, not a full XML parser. It reads only `<testsuite>`,
`<testcase>`, and the `<failure>`, `<error>`, and `<skipped>` children of a
test case, and skips text, comments, CDATA, and processing instructions.

How a report maps onto `Red.Case`:

* file: the test case's `file` attribute, or its enclosing suite's;
* `<error>` means `errored` (a load, setup, or collection error), `<failure>`
  means `failed` (an assertion), `<skipped>` means `skipped`; if a case has
  several, the worst one counts;
* a suite with `errors > 0` and no test cases (some runners report a file that
  failed to load this way) becomes one `errored` case.

The parser isn't proved correct. `Factory.Tests` checks it against real
pytest and jest-junit reports.
-/

namespace Factory.JUnit
open Factory.Red

structure Tag where
  name : String
  attrs : List (String × String)
  closing : Bool
  selfClosing : Bool
  deriving Repr

def Tag.attr (t : Tag) (k : String) : String :=
  (t.attrs.find? (·.1 == k)).map (·.2) |>.getD ""

def matchAt (cs : Array Char) (i : Nat) (lit : String) : Bool :=
  (List.range lit.length).all fun k => cs[i + k]? == lit.toList[k]?

/-- Index just past the next occurrence of `lit` at or after `i` (or the end). -/
partial def skipPast (cs : Array Char) (i : Nat) (lit : String) : Nat :=
  if i ≥ cs.size then cs.size
  else if matchAt cs i lit then i + lit.length
  else skipPast cs (i + 1) lit

def unescape (s : String) : String :=
  (((s.replace "&lt;" "<").replace "&gt;" ">").replace "&quot;" "\"").replace "&apos;" "'"
    |>.replace "&amp;" "&"

def isNameEnd (c : Char) : Bool := c.isWhitespace || c == '/' || c == '>' || c == '='

partial def readWhile (cs : Array Char) (i : Nat) (p : Char → Bool) (acc : String := "") :
    String × Nat :=
  match cs[i]? with
  | some c => if p c then readWhile cs (i + 1) p (acc.push c) else (acc, i)
  | none => (acc, i)

partial def skipWs (cs : Array Char) (i : Nat) : Nat :=
  match cs[i]? with
  | some c => if c.isWhitespace then skipWs cs (i + 1) else i
  | none => i

/-- Attributes up to the end of a start tag. Returns them, whether the tag
self-closes, and the index after `>`. -/
partial def readAttrs (cs : Array Char) (i : Nat) (acc : List (String × String) := []) :
    List (String × String) × Bool × Nat :=
  let i := skipWs cs i
  match cs[i]? with
  | none => (acc.reverse, false, i)
  | some '>' => (acc.reverse, false, i + 1)
  | some '/' => (acc.reverse, true, skipPast cs i ">")
  | some _ =>
    let (k, j) := readWhile cs i (fun c => !isNameEnd c)
    let j := skipWs cs j
    if cs[j]? == some '=' then
      let j := skipWs cs (j + 1)
      match cs[j]? with
      | some q =>
        if q == '"' || q == '\'' then
          let (v, e) := readWhile cs (j + 1) (· != q)
          readAttrs cs (e + 1) ((k, unescape v) :: acc)
        else
          let (v, e) := readWhile cs j (fun c => !c.isWhitespace && c != '>' && c != '/')
          readAttrs cs e ((k, unescape v) :: acc)
      | none => (acc.reverse, false, j)
    else if j == i then readAttrs cs (i + 1) acc  -- stray character
    else readAttrs cs j ((k, "") :: acc)

partial def scan (cs : Array Char) (i : Nat) (acc : Array Tag) : Array Tag :=
  if i ≥ cs.size then acc
  else if cs[i]! != '<' then scan cs (i + 1) acc
  else if matchAt cs i "<!--" then scan cs (skipPast cs i "-->") acc
  else if matchAt cs i "<![CDATA[" then scan cs (skipPast cs i "]]>") acc
  else if matchAt cs i "<?" || matchAt cs i "<!" then scan cs (skipPast cs i ">") acc
  else if matchAt cs i "</" then
    let (n, j) := readWhile cs (i + 2) (fun c => !isNameEnd c)
    scan cs (skipPast cs j ">") (acc.push { name := n, attrs := [], closing := true, selfClosing := false })
  else
    let (n, j) := readWhile cs (i + 1) (fun c => !isNameEnd c)
    let (attrs, sc, k) := readAttrs cs j
    scan cs k (acc.push { name := n, attrs, closing := false, selfClosing := sc })

def tags (xml : String) : Array Tag := scan xml.toList.toArray 0 #[]

def rank : Outcome → Nat
  | .passed => 0 | .skipped => 1 | .failed => 2 | .errored => 3

def worse (a b : Outcome) : Outcome := if rank b > rank a then b else a

structure Suite where
  file : String
  name : String
  errors : Nat
  cases : Nat

structure St where
  suites : List Suite := []
  cur : Option Case := none
  out : Array Case := #[]

def St.closeCase (st : St) : St :=
  match st.cur with
  | some c => { st with cur := none, out := st.out.push c }
  | none => st

def St.closeSuite (st : St) : St :=
  let st := st.closeCase
  match st.suites with
  | s :: rest =>
    let out := if s.cases == 0 && s.errors > 0 then
      st.out.push { file := s.file, name := s.name, outcome := .errored } else st.out
    { st with suites := rest, out }
  | [] => st

def step (st : St) (t : Tag) : St :=
  match t.name, t.closing with
  | "testsuite", false =>
    let s : Suite := { file := t.attr "file", name := t.attr "name",
                       errors := (t.attr "errors").toNat?.getD 0, cases := 0 }
    let st := { st with suites := s :: st.suites }
    if t.selfClosing then st.closeSuite else st
  | "testsuite", true => st.closeSuite
  | "testcase", false =>
    let st := st.closeCase
    let suiteFile := (st.suites.head?.map (·.file)).getD ""
    let file := if t.attr "file" != "" then t.attr "file" else suiteFile
    let cname := t.attr "classname"
    let name := if cname.trimAscii.isEmpty then t.attr "name" else s!"{cname.trimAscii} > {(t.attr "name").trimAscii}"
    let suites := match st.suites with
      | s :: rest => { s with cases := s.cases + 1 } :: rest
      | [] => []
    let st := { st with suites, cur := some { file, name, outcome := .passed } }
    if t.selfClosing then st.closeCase else st
  | "testcase", true => st.closeCase
  | n, false =>
    let o? : Option Outcome := match n with
      | "failure" => some .failed | "error" => some .errored | "skipped" => some .skipped
      | _ => none
    match o?, st.cur with
    | some o, some c => { st with cur := some { c with outcome := worse c.outcome o } }
    | _, _ => st
  | _, true => st

/-- Every test case in a JUnit XML report. -/
def parse (xml : String) : Array Case :=
  let st := (tags xml).foldl step {}
  -- Close anything a truncated report left open.
  (st.suites.foldl (fun st _ => st.closeSuite) st.closeCase).out

end Factory.JUnit
