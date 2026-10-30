---
name: NLSpec (feature for agent workflow)
about: A rigid, structured feature spec consumed by the QA and coder agents.
title: "[NLSpec] "
labels: ["nlspec"]
---

<!--
DRAFT — starter content, revise me.

This issue body is read directly by the QA agent (.factory/qa.nlspec.md) and
the coder agent (.factory/coder.nlspec.md). Fill out every section. Be
specific and unambiguous — vague sections come back as open questions in
the PR (via .factory/ambiguity-checklist.md) instead of working code.

Do not delete sections, even if "N/A" — an empty/missing section is treated
as undefined, not "no constraint".
-->

## Context

<!-- Why does this change exist? What problem does it solve? Link related
     issues/PRs if any. -->

## User Story

<!-- As a <role>, I want <capability>, so that <benefit>. -->

## Acceptance Criteria

<!--
Numbered, testable, observable. Each one should be checkable by a single
test (or small group of tests). The QA agent will tag tests with these IDs
(e.g. // AC-1).

AC-1:
AC-2:
AC-3:
-->

## API/Data Contract

<!--
For each new/changed endpoint or data shape:
- Method + path
- Request body / params (with types and which fields are required)
- Response body (success) with types
- Response status codes and error shapes
- Any new/changed database columns, tables, or migrations
-->

## Edge Cases

<!--
Boundary conditions, invalid input, empty states, concurrent access,
permission edge cases, etc. Each should map to an Acceptance Criterion above
(or add one).
-->

## Out of Scope

<!--
Explicitly list what this issue does NOT cover, especially anything a
reasonable implementer might assume is included. This is the coder agent's
primary defense against scope creep.
-->

## Non-Functional Constraints

<!--
Performance, security, accessibility, browser/Node version support,
backward compatibility, etc. Include anything from .factory/rubric.json that
this feature must specifically satisfy.
-->
