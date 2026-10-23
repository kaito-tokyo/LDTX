# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1037 @LDTXApp
Feature: LDTXApp wire application actions

  @LUB-1037.1 @UI
  Scenario: Route main menu commands
    Given the launched application with a supported document context
    When a main menu command is invoked
    Then the corresponding application or document action is reached

  @LUB-1037.2 @UIComponent
  Scenario: Retain Workspace coordinators until close completes
    Given an application with an open Workspace
    When the Workspace begins asynchronous closure
    Then the application retains its coordinator until cleanup finishes

  @LUB-1037.3 @Integration
  Scenario: Notify only after screenshot writes succeed
    Given a screenshot action using controllable storage and notification services
    When the capture is saved successfully or saving fails
    Then a completion notification is submitted only for successful writes

