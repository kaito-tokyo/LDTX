# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1038 @LDTXAppHelper
Feature: LDTXAppHelper serve automation requests

  @LUB-1038.1 @Unit
  Scenario: Expose supported automation operations
    Given an automation server with a fake operation service
    When tools are listed and a supported tool is called
    Then the advertised operation is dispatched to the service

  @LUB-1038.2 @Unit
  Scenario: Return protocol errors
    Given an invalid JSON-RPC request or unsupported method
    When the server handles the request
    Then the response reports the corresponding protocol error with the request identity when available

