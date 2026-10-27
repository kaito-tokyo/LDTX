// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#import <Foundation/Foundation.h>
#import <QuickLookUI/QuickLookUI.h>

NS_ASSUME_NONNULL_BEGIN

static NSURL *_Nullable LDTXMainMediaURLForRecordPackage(NSURL *packageURL) {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  NSArray<NSURL *> *candidateURLs = @[
    [packageURL URLByAppendingPathComponent:@"landscape.fragmented.mp4" isDirectory:NO],
    [packageURL URLByAppendingPathComponent:@"portrait.fragmented.mp4" isDirectory:NO],
  ];

  for (NSURL *candidateURL in candidateURLs) {
    BOOL isDirectory = NO;
    if ([fileManager fileExistsAtPath:candidateURL.path isDirectory:&isDirectory] && !isDirectory) {
      return candidateURL;
    }
  }

  return nil;
}

@interface LDTXQuickLookPreviewProvider : QLPreviewProvider <QLPreviewingController>
@end

@implementation LDTXQuickLookPreviewProvider

- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request
                   completionHandler:(void (^)(QLPreviewReply *_Nullable, NSError *_Nullable))handler {
  NSURL *mediaURL = LDTXMainMediaURLForRecordPackage(request.fileURL);

  if (mediaURL == nil) {
    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
    handler(nil, error);
  } else {
    QLPreviewReply *reply = [[QLPreviewReply alloc] initWithFileURL:mediaURL];
    handler(reply, nil);
  }
}

@end

NS_ASSUME_NONNULL_END
