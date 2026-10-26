---
name: update-gitmodules-metadata
description: Update or verify .gitmodules archive URLs and SHA-256 hashes using x-tag as the source of truth.
---

<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
SPDX-License-Identifier: Apache-2.0
-->

# Update .gitmodules metadata

`x-tag` is the literal upstream Git tag and the source of truth. Keep these keys
in order: `x-tag`, `x-tarball-url`, `x-tarball-hash`, `x-zip-url`, `x-zip-hash`.
Hashes use `sha256:<64 lowercase hexadecimal digits>` for the archive bytes.

1. Set the requested `x-tag`. Check that its peeled commit (`TAG^{commit}`)
   matches the intended submodule revision and gitlink; preserve local changes.
2. Run from the repository root, passing the submodule path:

   ```sh
   /bin/bash .agents/skills/update-gitmodules-metadata/scripts/get_submodule_metadata Vendors/nanopb
   ```

3. Use the four URL/hash values on stdout to edit the selected `.gitmodules`
   section. The script never edits files; exit status 1 indicates a mismatch.
   Preserve unrelated sections, comments, and unknown keys. Rerun to verify.

The script uses a fixed path-to-base-URL table. Update it when adding support
for a dependency or changing its upstream. Do not guess hashes or reuse them
for different URLs. Report download failures separately from metadata mismatches.

For restoration, recover the exact previous values without upgrading the
submodule. For revision changes, also check affected runtime/generator pins and
run the relevant build or generator checks. Finish with `git diff --check`.
