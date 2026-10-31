// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

#import <XCTest/XCTest.h>
#import <WorkspaceAudioEngine.h>

@interface LDTXAudioKitTests : XCTestCase
@end

@implementation LDTXAudioKitTests

- (void)testAudioEngineCanBeCreatedWithoutHardware {
  LDTXWorkspaceAudioEngine *engine = LDTXAudioCreate(false);
  XCTAssertNotEqual(engine, NULL);
  LDTXAudioDestroy(engine);
}

@end
