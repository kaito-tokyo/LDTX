# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@UCT-1012 @AudioMixEditor
Feature: Edit channel gains

  @UCT-1012.1
  Scenario: Channel gains can be edited without selecting a Program or canvas
    Given an Audio Mix Editor with an input but no selected Program
    When the user adjusts its gain and invalid gains are subsequently requested
    Then the valid gain is stored without changing canvas selection and invalid edits retain it

  @UCT-1012.2 @AudioDecibelField
  Scenario: Numeric gain drafts survive refresh and failed commit
    Given a gain field contains an unconfirmed numeric draft
    When the model refreshes and the first commit fails before a successful retry
    Then the draft survives refresh and failure and the retry commits that draft
