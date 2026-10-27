# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1023 @LDTXVision
Feature: Recognize text and classify images

  @LUB-1023.1 @Integration
  Scenario: Recognize text using configured languages
    Environment constraint: GitHub Actions hosted arm64 VMs can fail real OCR
    with E5RT error 11 and "No available backends on platform [universal] for
 compute units ane". PR and main workflows now include
    WorkspaceClockOCRIntegrationTestSuite and ManualOCRRecognitionIntegrationTestSuite.
    Run real recognition on a supported Mac; local plans and Xcode Cloud retain it.
    Keep these CI exclusions unless backend availability is verified on the runner.
    A skipped recognition test does not demonstrate successful OCR. Deterministic
    control, failure, retry, and publication tests remain enabled in GitHub Actions.

    Given a known text image and an OCR configuration on a supported backend
    When text recognition completes
    Then the returned text matches the fixture's expected text

  @LUB-1023.2 @Integration
  Scenario: Honor classifier image preprocessing metadata
    Given an image classifier declaring scaleFit preprocessing metadata
    When the classifier is prepared
    Then image preprocessing uses scale-to-fit rather than center crop

  @LUB-1023.3 @Integration
  Scenario: Reject a non-classifier model
    Given a feature extractor without predicted labels and class probabilities
    When the image classifier service is constructed
    Then construction fails before classification is attempted

  @LUB-1023.4 @Integration
  Scenario: Bound recognition snapshots and honor subsampling
    Given a 1920 by 1080 input image and a single-slot frame copier
    When a snapshot is requested with subsampling rate 2
    Then the snapshot is 960 by 540 pixels
    And another copy is unavailable until that snapshot is released
