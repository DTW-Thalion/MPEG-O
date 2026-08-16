/*
 * TTIOPackedReference.h
 * TTI-O Objective-C Implementation
 *
 * Packed storage for embedded reference chromosomes — 2-bit body +
 * run mask. Cross-language byte-exact with Python
 * ttio.genomic.packed_reference and Java
 * global.thalion.ttio.genomics.PackedReference; wire layout in
 * docs/format-spec.md §10.10.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"

NS_ASSUME_NONNULL_BEGIN

@interface TTIOPackedReference : NSObject

/** Fraction of bytes that are uppercase ACGT (1.0 for empty input). */
+ (double)packableFraction:(NSData *)data;

/** Pack data into the data_packed layout; lossless for any bytes. */
+ (NSData *)encode:(NSData *)data;

/** Inverse of encode. Returns nil and fills error on a malformed stream. */
+ (nullable NSData *)decode:(NSData *)stream error:(NSError **)error;

/**
 * The pack decision: returns the bytes to store and sets *outName to
 * "data_packed" when the packed layout is smaller, else returns seq
 * itself with *outName = "data". Deterministic on content, so all
 * three languages choose the same layout for the same sequence.
 */
+ (NSData *)payloadForSequence:(NSData *)seq
                   datasetName:(NSString * _Nonnull * _Nonnull)outName;

/**
 * Write one chromosome's bytes under chromGroup — as data_packed when
 * the packed layout is smaller, else as the legacy raw data dataset.
 * The pack decision (ACGT-fraction gate + exact size comparison) is
 * deterministic on content, so all three languages choose the same
 * layout for the same sequence.
 */
+ (BOOL)writeChromosomeDataset:(id<TTIOStorageGroup>)chromGroup
                      sequence:(NSData *)seq
                         error:(NSError **)error;

/**
 * Read one chromosome's bytes from chromGroup, decoding data_packed
 * when present and falling back to the legacy raw data dataset.
 */
+ (nullable NSData *)readChromosomeBytes:(id<TTIOStorageGroup>)chromGroup
                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
