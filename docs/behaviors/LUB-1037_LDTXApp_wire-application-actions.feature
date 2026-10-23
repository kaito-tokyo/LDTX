# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1037 @LDTXApp
Feature: LDTXApp wire application actions

  @LUB-1037.1 @UI
  Scenario: Open Vision Programmer from each application scene
    Given the application showing a Workspace, Record Player, Settings, or Vision Programmer scene
    When the Vision Programmer main-menu command is invoked
    Then exactly one enabled command is offered and the Scene Detector window opens

  @LUB-1037.2 @UIComponent
  Scenario: Retain Workspace coordinators until close completes
    Given an application with an open Workspace and suspended cleanup
    When the Workspace begins closing
    Then the application retains its coordinator until cleanup completes and then unregisters it

  @LUB-1037.3 @Integration
  Scenario: Notify only after screenshot writes succeed
    Given a screenshot action with controllable storage and notification delivery
    When saving finishes
    Then successful writes submit a completion notification and failed writes do not
