---
# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

name: ldtx-generate-xctestplan
description: Generate or verify LDTX's Xcode test plans after changes to test targets or shard settings.
---

From the repository root, generate the Xcode project and then the checked-in
test plans:

```sh
xcodegen generate
python3 .agents/skills/ldtx-generate-xctestplan/scripts/generate-test-plans.py
```

The script reads target identifiers from the generated project. Its `PLANS`
and `ALL_TARGETS` definitions control plan configuration and target membership;
UI test suites declare their shard in Swift. Update these definitions when the
requested change alters the plans, then inspect the generated diff.

Run the script with `--check` to compare the expected plan contents without
writing files. The CI workflow runs this check after generating the project.
