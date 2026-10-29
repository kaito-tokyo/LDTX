# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1058 @LDTXProgramRuntime
Feature: deliver preview frames and accessibility

  @LUB-1058.1 @Integration
  Scenario: Bound slow preview consumers
    Given a frame mailbox with an in-flight delivery and several newer frames
    When the consumer resumes
    Then pending frames coalesce to the latest frame and another mailbox still receives execution time

  @LUB-1058.2 @Integration
  Scenario: Drain frame subscriptions on cancellation
    Given a frame subscription with pending and in-flight delivery
    When the subscription is cancelled or its runtime is released
    Then pending work is dropped and cancellation waits for in-flight delivery before releasing captures

  @LUB-1058.3 @Integration
  Scenario: Render independent paired previews
    Given different Landscape and Portrait compositions sharing a preview surface
    When preview regions are laid out and rendered
    Then aspect ratios, equal heights, and the gap are preserved without overwriting neighboring regions

  @LUB-1058.4 @Integration
  Scenario: Read current pixels only for accessibility image requests
    Given an accessible preview with current canvas content
    When accessibility queries metadata or requests image data
    Then metadata queries avoid GPU readback and image requests return current pixels for the selected canvas

  @LUB-1058.5 @UIComponent
  Scenario: Keep preview identity and canvas selection stable
    Given a represented paired preview
    When selection or its parent view changes
    Then the same preview remains addressable and selection actions target the requested canvas

  @LUB-1058.6 @UIComponent
  Scenario: Restore preview height by Workspace identity
    Given a Workspace with a saved preview height
    When its content is reopened or its saved identity is adopted
    Then the preview height for that Workspace identity is restored
