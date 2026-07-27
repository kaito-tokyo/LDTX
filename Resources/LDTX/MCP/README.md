<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX MCP server

LDTX provides a local stdio MCP server at `Contents/Library/Helpers/LDTXHelper mcp`.
The independently installed CLI provides the same server as `ldtx mcp`.
The `diagnostics_query_samples` tool returns unaggregated process-load rows
whose UTC timestamps fall in a requested half-open range.
When the server runs as the independently installed `ldtx mcp`, callers must
provide both `bundleId` and `appVersion`; the app-bundled server resolves them
from its enclosing application.
