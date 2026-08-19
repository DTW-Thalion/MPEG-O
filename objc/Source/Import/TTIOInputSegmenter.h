/* SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * TTIOInputSegmenter — classifies an import input for the parallel
 * producers. Seekable plain files shard; everything else (gzip
 * streams, pipes) is pipeline mode. The caller never chooses.
 */
#ifndef TTIO_INPUT_SEGMENTER_H
#define TTIO_INPUT_SEGMENTER_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TTIOInputMode) {
    TTIOInputModePipeline = 0,
    TTIOInputModeShard    = 1,
};

NS_ASSUME_NONNULL_BEGIN

@interface TTIOInputSegmenter : NSObject

/** Shard iff <code>path</code> is a seekable regular file that does
 *  not start with the gzip magic. */
+ (TTIOInputMode)modeForPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END

#endif
