<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX Unit Behavior

LUB describes current observable behavior in English Gherkin, with one Feature
per file. Use these contracts to identify necessary, redundant, and obsolete
tests. Features describe expectations, not test results.

## Format

- Keep files directly in this directory. Use a flat sequence of LUB IDs without
  module ranges or hierarchy; a module may have multiple Features.
- Name files `LUB-1000_LDTXModule_short-description.feature`.
- Tag each Feature with its ID and primary module: `@LUB-1000 @LDTXModule`.
- Tag Scenarios consecutively from `@LUB-1000.1`, without gaps or leading zeros.
- Add one scope tag per Scenario: `@Unit`, `@Integration`, `@UIComponent`, `@UI`,
  or `@XPC`.
- Describe one observable contract per Scenario using Given, When, and Then.
  Cover meaningful outcomes and failures, not private implementation steps or
  individual assertions. Group equivalent inputs as test data.

## Maintenance

- Assign new numbers sequentially. Keep existing IDs; leave retired numbers
  unused without renumbering or maintaining a retirement registry.
- Delete obsolete Features, Scenarios, and tests. Do not retain their contents
  in archives, comments, history documents, or completed review notes.
- Keep tests that protect distinct current contracts. Consolidate duplicates
  and prefer the cheapest reliable verification boundary. Check for a missing
  contract before deleting an unmapped test; no fixed test count or one-to-one
  Scenario-to-test mapping is required.
- Keep this README limited to rules. Case additions and removals require no
  README update; do not add indexes, counts, coverage status, or progress reports.
