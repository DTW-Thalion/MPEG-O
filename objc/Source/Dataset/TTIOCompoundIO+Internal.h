/*
 * TTIOCompoundIO+Internal.h
 * TTI-O Objective-C Implementation
 *
 * Internal (SPI) surface of TTIOCompoundIO. NOT part of the public
 * umbrella header — only the few in-tree call sites that need the
 * column-oriented fast path import this directly.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_COMPOUND_IO_INTERNAL_H
#define TTIO_COMPOUND_IO_INTERNAL_H

#import "TTIOCompoundIO.h"

@class TTIOCompoundField;
@protocol TTIOStorageGroup;

@interface TTIOCompoundIO (Internal)

/**
 * Column-oriented sibling of
 * <code>+writeGeneric:intoGroup:datasetNamed:fields:error:</code>.
 *
 * Writes the SAME on-disk compound dataset as writeGeneric for the
 * same logical data, but sources values column-wise to avoid building
 * one NSDictionary (and the NSNumber boxing) per row on the hot
 * per-AU encryption write path.
 *
 * <code>columns</code> is keyed by field name; the value for each
 * field depends on its kind:
 *   - UInt32:   NSData of <code>count</code> packed C uint32_t, OR
 *               NSArray<NSNumber*> of length <code>count</code>.
 *   - Int64:    NSData of <code>count</code> packed C int64_t, OR
 *               NSArray<NSNumber*>.
 *   - Float64:  NSData of <code>count</code> packed C double, OR
 *               NSArray<NSNumber*>.
 *   - VLString: NSArray<NSString*> of length <code>count</code>.
 *   - VLBytes:  NSArray<NSData*> of length <code>count</code>.
 *
 * Packed-NSData columns for primitives are preferred (zero boxing).
 *
 * @param columns  Per-field column data keyed by field name.
 * @param parent   Destination parent group.
 * @param name     Dataset name.
 * @param fields   Schema definition (same as writeGeneric).
 * @param count    Number of rows.
 * @param error    Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
+ (BOOL)writeColumnar:(NSDictionary<NSString *, id> *)columns
            intoGroup:(id<TTIOStorageGroup>)parent
         datasetNamed:(NSString *)name
               fields:(NSArray<TTIOCompoundField *> *)fields
                count:(NSUInteger)count
                error:(NSError **)error;

@end

#endif /* TTIO_COMPOUND_IO_INTERNAL_H */
