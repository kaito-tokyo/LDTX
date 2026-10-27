// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#import <AVFoundation/AVFoundation.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <dispatch/dispatch.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

static os_log_t logger(void) { return os_log_create("tokyo.kaito.ldtx", "QuickLookThumbnail"); }

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

static NSError *LDTXThumbnailGenerationError(NSError *_Nullable error) {
  return error ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
}

static QLThumbnailReply *_Nullable LDTXThumbnailReplyForImage(CGImageRef image, CGSize minimumSize, CGSize maximumSize,
                                                              CGFloat requestScale) {
  id imageObject = CFBridgingRelease(CGImageRetain(image));
  CGSize imageSize = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
  CGFloat fitScale = MIN(maximumSize.width / imageSize.width, maximumSize.height / imageSize.height);
  CGSize fittedSize = CGSizeMake(imageSize.width * fitScale, imageSize.height * fitScale);
  CGSize contextSize = CGSizeMake(MIN(MAX(fittedSize.width, minimumSize.width), maximumSize.width),
                                  MIN(MAX(fittedSize.height, minimumSize.height), maximumSize.height));
  CGRect drawRect = CGRectMake((contextSize.width - fittedSize.width) / 2, (contextSize.height - fittedSize.height) / 2,
                               fittedSize.width, fittedSize.height);

  QLThumbnailReply *reply = [QLThumbnailReply replyWithContextSize:contextSize
                                                      drawingBlock:^BOOL(CGContextRef context) {
                                                        CGImageRef retainedImage = (__bridge CGImageRef)imageObject;
                                                        CGContextScaleCTM(context, requestScale, requestScale);
                                                        CGContextDrawImage(context, drawRect, retainedImage);
                                                        return YES;
                                                      }];
  reply.extensionBadge = @"LDTX";
  return reply;
}

@interface LDTXThumbnailProvider : QLThumbnailProvider
@end

@implementation LDTXThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                     completionHandler:(void (^)(QLThumbnailReply *_Nullable reply, NSError *_Nullable error))handler {
  NSURL *mediaURL = LDTXMainMediaURLForRecordPackage(request.fileURL);

  if (mediaURL == nil) {
    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
    handler(nil, error);
    return;
  }

  CGSize minimumSize = request.minimumSize;
  CGSize maximumSize = request.maximumSize;
  CGFloat requestScale = request.scale;
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL options:nil];
  AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;
  generator.maximumSize = CGSizeMake(maximumSize.width * requestScale, maximumSize.height * requestScale);

  void (^completionHandler)(CGImageRef _Nullable image, CMTime, NSError *_Nullable error) =
      ^(CGImageRef _Nullable image, CMTime actualTime, NSError *_Nullable error) {
        if (image == nil) {
          os_log_error(logger(),
                       "Failed to generate thumbnail at time {value: %lld, timescale: %d, epoch: %lld, flags: %u}",
                       actualTime.value, actualTime.timescale, actualTime.epoch, actualTime.flags);
          handler(nil, LDTXThumbnailGenerationError(error));
          return;
        }

        QLThumbnailReply *reply = LDTXThumbnailReplyForImage(image, minimumSize, maximumSize, requestScale);
        handler(reply, nil);
      };

  [generator generateCGImageAsynchronouslyForTime:kCMTimeZero completionHandler:completionHandler];
}

@end

NS_ASSUME_NONNULL_END
