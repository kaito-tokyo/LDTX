<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# UI Rules

This document defines UI-specific behavior, including presentation, interaction,
and user-facing naming rules. It does not define domain-model invariants,
persistence contracts, or runtime guarantees.

## Display name generation

- `display_name` values are unique across the entire Workspace UI.
- When adding a Resource, Program, or Vision, include all existing Resource,
  Program, and Vision names in the candidate-name set.
- If the preferred name is already used, append a numeric suffix to make it
  unique, such as `Video Input`, `Video Input 2`, and `Video Input 3`.
- Never automatically rename an existing item to make room for a new one.
