<!--
DRAFT — starter content, revise me.

This is the human merge checklist. The agent workflow may populate parts of
this automatically (e.g. rubric score), but a human must check the boxes and
approve before merge. Do not merge with unchecked required boxes.
-->

# Gatekeeper Checklist

## Linked spec

- [ ] This PR links to the originating NLSpec issue (`.github/ISSUE_TEMPLATE/nlspec.md`).
- [ ] All Acceptance Criteria in that issue are addressed by this PR (or
      explicitly deferred with a new follow-up issue linked below).

Linked issue: #
Follow-up issue(s) (if any): #

## Tests

- [ ] New/updated tests live inside the QA write scope (`.paths.qa`) and
      follow the `AC-n` tagging convention from `.factory/qa.nlspec.md`.
- [ ] The protected paths (`.paths.protected`, e.g. the shared test harness)
      were **not** modified by this PR.
- [ ] The test command (`product.test`) passes locally / in CI, including the
      new tests, and the test setup itself (scripts, runner config) wasn't
      changed to get there.
- [ ] Every Acceptance Criterion in the linked issue maps to at least one
      test.

## Rubric (`.factory/rubric.json`)

- [ ] Reviewed against the rubric's `security`, `architecture`, and `style`
      dimensions.
- [ ] Overall score meets `passThreshold` (currently `75`).

Score: ___ / 100 — Security: ___ Architecture: ___ Style: ___

## Scope & ambiguity

- [ ] Changes are limited to what the linked issue requires (no unrelated
      refactors).
- [ ] Every item under "Ambiguities recorded by the agents" (below, if
      present) has been resolved or explicitly accepted.

## Manual verification

- [ ] I ran the product locally and exercised the changed behavior
      end-to-end.
- [ ] Privileged actions were verified as rejected for unauthorized
      requests, where applicable.

## Notes for reviewer

<!-- Anything the gatekeeper should pay special attention to. -->
