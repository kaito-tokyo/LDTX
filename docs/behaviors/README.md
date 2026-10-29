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
- Explicitly name every Swift Testing test with its LUB ID and readable case name
  in `@Test("LUB-1000: Preserve rational representations")`.
- Describe one observable contract per Scenario using Given, When, and Then.
  Specify one SUT's public behavior, not helper calls, framework functionality,
  individual assertions, or a sequence of unrelated operations.
- Use Scenario Outline and Examples when situations vary. Put initial state,
  input, and expected outcome in meaningful columns; keep a plain Scenario for
  a single situation. Do not invent parameters solely to use an Outline.
- UI tests use typed, independently runnable `@Test(arguments:)` datasets for
  shared behavior. Describe situations with data, not case names or operation
  scripts. Match Examples and Swift datasets by meaning without a runtime link.

## Maintenance

- Assign new numbers sequentially. Keep existing IDs; leave retired numbers
  unused without renumbering or maintaining a retirement registry.
- Delete obsolete Features, Scenarios, and tests. Do not retain their contents
  in archives, comments, history documents, or completed review notes.
- Keep each SUT's distinct guarantees even when another layer has similar
  assertions. Remove redundant checks, framework-only tests, and trivial helper
  tests; retain direct tests of independently complex calculations or boundaries.
- Use equivalence classes and boundary values outside UI. Use explicit situation
  datasets for UI; require a behavioral reason for Cartesian products. Never
  combine unrelated behaviors merely to reduce the number of test declarations.
- Check for a missing contract before deleting an unmapped test. No fixed test
  count or one-to-one Scenario-to-test mapping is required.
- Keep this README limited to rules. Case additions and removals require no
  README update; do not add indexes, counts, coverage status, or progress reports.
