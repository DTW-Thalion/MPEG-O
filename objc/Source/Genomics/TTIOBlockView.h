/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_BLOCK_VIEW_H
#define TTIO_BLOCK_VIEW_H

#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"

@class TTIOBlockTable;

NS_ASSUME_NONNULL_BEGIN

/** One block of a blocks_v1 run materialised as a v1.8-shaped run group
 *  in a TTIOMemoryProvider store, so the existing TTIOGenomicRun decoders
 *  read it unchanged. Python: <code>_block_view</code>; Java:
 *  <code>BlockView</code>. */
@interface TTIOBlockView : NSObject

/** The materialised run group. */
@property (nonatomic, readonly) id<TTIOStorageGroup> group;

/** Copy block <code>b</code> of <code>runGroup</code> into a fresh memory
 *  store: the run attributes (less layout / block_policy / base_count),
 *  the sliced per-read index arrays, the block's channel blobs with
 *  their codec attributes, and the two name tables. */
+ (nullable instancetype)materialiseBlock:(NSUInteger)b
                                 ofRun:(id<TTIOStorageGroup>)runGroup
                                 table:(TTIOBlockTable *)table
                            chromNames:(NSArray<NSString *> *)chromNames
                        mateChromNames:(NSArray<NSString *> *)mateChromNames
                                 error:(NSError **)error;

/** As above, leaving out the blob channels named in
 *  <code>skipChannels</code> — the per-AU decrypt walker (M99) skips
 *  the encrypted (deleted) channels and injects their decrypted raw
 *  bytes itself. */
+ (nullable instancetype)materialiseBlock:(NSUInteger)b
                                 ofRun:(id<TTIOStorageGroup>)runGroup
                                 table:(TTIOBlockTable *)table
                            chromNames:(NSArray<NSString *> *)chromNames
                        mateChromNames:(NSArray<NSString *> *)mateChromNames
                          skipChannels:(nullable NSSet<NSString *> *)skipChannels
                                 error:(NSError **)error;

/** Drop the memory store. */
- (void)discard;

/** The <code>name</code> column of a one-column VL-string table, or an
 *  empty array when the dataset is absent. */
+ (NSArray<NSString *> *)readNamesIn:(id<TTIOStorageGroup>)group named:(NSString *)name;

@end

NS_ASSUME_NONNULL_END

#endif
