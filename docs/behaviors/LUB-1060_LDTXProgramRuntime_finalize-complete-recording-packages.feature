# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

@LUB-1060 @LDTXProgramRuntime
Feature: finalize complete recording packages

  @LUB-1060.1 @Integration
  Scenario: Finalize only usable media
    Given a recording with missing main audio, video, or a failed side track
    When finish is requested
    Then the package is not marked finalized unless all required media and finalization hooks succeed

  @LUB-1060.2 @Integration
  Scenario: Preserve audio timing through recording and remux
    Given recorded audio with source-clock drift, partial input loss, or sub-sample start offsets
    When the package is finalized and remuxed
    Then audio remains decodable and retains its relationship to the video timeline

  @LUB-1060.3 @Integration
  Scenario: Keep writer failure terminal and observable
    Given a recording track with accepted work and an append or asynchronous writer failure
    When more writes or concurrent finish requests arrive
    Then later writes are rejected and finish callers receive the original failure after accepted work is reconciled

  @LUB-1060.4 @Integration
  Scenario: Bound incomplete muxed media
    Given a muxed recording whose audio or video stalls
    When additional media arrives on the other track
    Then the pending sample count and duration are bounded and overflow is reported

  @LUB-1060.5 @Unit
  Scenario: Keep recording tracks distinct across canvases
    Given logical audio inputs with colliding names or reserved mix identifiers
    When recording track descriptors are created
    Then distinct inputs receive distinct safe track identifiers while shared physical inputs produce one side track

  @LUB-1060.6 @Integration
  Scenario Outline: Create media files only for enabled canvases
    Given landscape recording <landscape> and portrait recording <portrait>
    When accepted media is recorded and finalized
    Then the package contains <files>

    Examples:
      | landscape | portrait | files                               |
      | true      | false    | landscape media only                |
      | false     | true     | portrait media only                 |
      | true      | true     | landscape and portrait media         |

  @LUB-1060.7 @Integration
  Scenario: Stop without fabricating an empty recording
    Given a recording session that has not accepted its first video sample
    When the session stops normally
    Then stopping succeeds without creating a recording package
