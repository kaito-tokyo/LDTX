# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1024 @LDTXVisionTraining
Feature: LDTXVisionTraining train and export scene detectors

  @LUB-1024.1 @Integration
  Scenario: Train from class folders
    Given a small labeled image dataset with one folder per class
    When training completes and the model is exported
    Then the exported model can be loaded with the dataset's class labels

  @LUB-1024.2 @Integration
  Scenario: Use the declared preprocessing contract
    Given scene detector training configured for Image Feature Print V2
    When training input is prepared
    Then aspect ratio is preserved using scale-to-fit without augmentation

