# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1017 @LDTXYouTube
Feature: LDTXYouTube handle live api responses

  @LUB-1017.1 @Unit
  Scenario: Build a live API request
    Given a fake API transport and a request to list upcoming broadcasts
    When the client performs the operation
    Then the request uses GET with broadcastStatus set to upcoming and broadcastType set to event
    And the request does not include a mine filter

  @LUB-1017.2 @Unit
  Scenario: Surface unsuccessful API responses
    Given an unsuccessful response from a fake API transport
    When the response is processed
    Then the caller receives a failure rather than a successful live resource

