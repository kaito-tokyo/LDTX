<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# LDTX MCP server

LDTX provides a local stdio MCP server.

Executable: `Contents/Library/Helpers/LDTXHelper`

Arguments: `mcp`

Connect with MCP `initialize`, then `tools/list`.

`stdout` is reserved for MCP messages; diagnostics use `stderr`.

The client must start the executable directly and own its standard input and
standard output. The executable path above is relative to the root of
`LDTX.app`. An independently installed CLI provides the same server as
`/usr/local/bin/ldtx mcp`.
