import Factory.Cli

/-!
# Build-time tests

Everything here runs during `lake build`, so a failing check fails the build,
the same way an unproved theorem does. The JUnit fixtures in `tests/fixtures/`
are real reports from pytest and jest-junit (paths and hostnames scrubbed).
-/

namespace Factory.Tests
open Factory

/-! ## Path gate -/

def qa : PathGate.Scope := { allowed := ["tests/"], protect := ["tests/golden/"] }

#guard PathGate.acceptPaths qa ["tests/a.test.js"]
#guard !PathGate.acceptPaths qa []
#guard !PathGate.acceptPaths qa ["tests/golden/app.js"]
#guard !PathGate.acceptPaths qa ["tests/a.test.js", "src/x.py"]
#guard PathGate.violations qa ["tests/a.py", "tests/golden/db.py", "README.md"] ==
  ["tests/golden/db.py", "README.md"]
#guard !PathGate.validPrefix "tests" && PathGate.validPrefix "tests/" && !PathGate.validPrefix "/"
#guard PathGate.accept qa [.rename "tests/golden/app.js" "tests/app.js"] == false

/-! ## JUnit + red check on real reports -/

def casesOf (path : String) : IO (List Red.Case) := do
  return (JUnit.parse (← IO.FS.readFile path)).toList

def expect (what : String) (ok : Bool) : IO Unit :=
  unless ok do throw (IO.userError s!"test failed: {what}")

#eval show IO Unit from do
  -- pytest (junit_family=xunit1): one assertion failure in the new file.
  let cs ← casesOf "tests/fixtures/pytest-red.xml"
  expect "pytest-red: 3 cases" (cs.length == 3)
  expect "pytest-red: outcomes" (cs.map (·.outcome) == [.failed, .skipped, .passed])
  expect "pytest-red: files" (cs.map (·.file) == ["tests/test_new.py", "tests/test_new.py", "tests/test_ok.py"])
  expect "pytest-red: red for the right reason" (Red.redOk ["tests/test_new.py"] cs)
  expect "pytest-red: failure outside QA's files" (!Red.redOk ["tests/test_other.py"] cs)
  -- pytest: a collection error (bad import) is not an assertion failure.
  let cs ← casesOf "tests/fixtures/pytest-error.xml"
  expect "pytest-error: errored" (cs.map (·.outcome) == [.errored])
  expect "pytest-error: rejected" (!Red.redOk ["tests/test_broken.py"] cs)
  -- pytest default (xunit2) has no file attribute: fail closed.
  let cs ← casesOf "tests/fixtures/pytest-xunit2.xml"
  expect "pytest-xunit2: unattributed" (cs.all (·.file == ""))
  expect "pytest-xunit2: fails closed" (!Red.redOk ["tests/test_new.py"] cs)
  -- jest-junit (addFileAttribute, reportTestSuiteErrors).
  let cs ← casesOf "tests/fixtures/jest-red.xml"
  expect "jest-red: 2 cases" (cs.length == 2)
  expect "jest-red: red for the right reason" (Red.redOk ["tests/new.test.js"] cs)
  expect "jest-red: not red if QA changed nothing failing" (!Red.redOk ["tests/ok.test.js"] cs)
  let cs ← casesOf "tests/fixtures/jest-error.xml"
  expect "jest-error: suite that failed to run is errored" (cs.any (fun c => c.outcome == .errored && c.file == "tests/broken.test.js"))
  expect "jest-error: rejected" (!Red.redOk ["tests/new.test.js", "tests/broken.test.js"] cs)

-- Hand-written edge cases for the scanner.
#guard (JUnit.parse "<testsuite file='a.py' errors='1' tests='0'></testsuite>").toList.map (·.outcome) == [.errored]
#guard (JUnit.parse "<testsuites><testsuite file=\"s.py\"><testcase name=\"t\"/></testsuite></testsuites>").toList.map (·.file) == ["s.py"]
#guard (JUnit.parse "<!-- <testcase name='x'/> --><testcase name='y' file='f'><![CDATA[<error/>]]></testcase>").toList.map (·.outcome) == [.passed]
#guard (JUnit.parse "<testcase name='z' file='f'><failure/><error/></testcase>").toList.map (·.outcome) == [.errored]

/-! ## Rubric -/

#guard Rubric.passCurrent [[100, 100, 100, 100], [100, 100, 100, 100, 100], [100, 100, 100]]
#guard !Rubric.passCurrent [[1000000, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0]]
#guard Cli.scoreOf (.num ⟨875, 1⟩) == 87
#guard Cli.scoreOf (.num ⟨1001, 1⟩) == -1
#guard Cli.scoreOf (.str "100") == -1

end Factory.Tests
