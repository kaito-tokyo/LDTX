<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Scenarios

This directory contains local UI verification scenarios for LDTX.
They are written for Computer-use assisted execution and are not CI gates.

## How to Read These Files

Each scenario is one Markdown file with YAML frontmatter followed by a test
case style body. The structure is intentionally close to common test case
descriptions found in software testing bodies of knowledge and standards:
identifier, purpose, priority, preconditions, procedure, expected result, and
postconditions.

Use the frontmatter first to decide whether a scenario should be run:

- `id`: Stable scenario identifier for reports and handoffs.
- `status`: `active`, `draft`, or `retired`.
- `priority`: `p0`, `p1`, or `p2`; lower numbers are more important.
- `risk`: Main product risk covered by the scenario.
- `feature`: Product area under verification.
- `test_level`: Usually `system` for app UI scenarios.
- `test_type`: Functional category such as `smoke`, `regression`, or `error-handling`.
- `execution`: Expected executor, usually `computer-use`.
- `automation`: `manual`, `assisted`, or `automated`.
- `run_when`: Change signals that make the scenario relevant.
- `requires`: Environment, data, or app state needed before execution.
- `tags`: Searchable labels for selecting related scenarios.

Then read the body as the executable test case:

- `Objective`: What behavior the scenario proves.
- `Preconditions`: State required before step 1.
- `Test Data`: Named data values used during execution.
- `Procedure`: Ordered user-visible actions.
- `Expected Results`: Observable outcomes that must hold.
- `Postconditions`: State that may remain after the scenario.
- `Notes`: Practical guidance for Computer-use or human execution.

## Execution Guidance

Run `p0` scenarios when the changed code affects the scenario's `feature`,
`risk`, or `tags`. Run `p1` scenarios when touching nearby UI flows. Run `p2`
scenarios before releases or when the scenario has recently failed.

Prefer a clean workspace state for every scenario. When possible, launch LDTX
with UI testing state isolation enabled so scenario results do not depend on
previous local app state.

