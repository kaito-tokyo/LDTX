<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX App Automation MCP server

LDTX provides an App Automation-only local stdio MCP server at
`Contents/Library/Helpers/LDTXHelper mcp`.

The MCP surface is provided by the app-bundled helper and does not expose
recording or workspace file operations. Use the standalone `ldtx` executable
for those operations.
