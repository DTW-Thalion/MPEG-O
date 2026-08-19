/* SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * TTIOFastqRecordScanner
 *
 * Finds record boundaries inside a byte range of a plain (unwrapped,
 * uncompressed) FASTQ file, so the shard-mode producer can split a
 * file into ranges that each start on a record.
 *
 * Boundary rule: a candidate is a '@' at offset 0 or one preceded by
 * '\n'. Because '@' (Phred 31) legally appears anywhere in a quality
 * string, a candidate confirms only when the line two lines below it
 * starts with '+'. The scanner walks forward candidate by candidate
 * inside a bounded window (1 MiB, doubled up to 16 MiB when a record
 * spans further) until one confirms.
 */
#ifndef TTIO_FASTQ_RECORD_SCANNER_H
#define TTIO_FASTQ_RECORD_SCANNER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TTIOFastqRecordScanner : NSObject

/** The byte offset of the first record start at or after
 *  <code>offset</code>, or <code>fileLength</code> when no boundary
 *  confirms before the end of the file. */
+ (long long)boundaryAtOrAfter:(long long)offset
                        inFile:(NSFileHandle *)fh
                    fileLength:(long long)fileLength;

/** YES when the '@' at <code>index</code> of <code>window</code> is a
 *  confirmed record start: the line two newlines further on starts
 *  with '+'. NO also when the window ends before the '+' line is
 *  reachable (the caller grows the window and retries). Exposed for
 *  the unit tests. */
+ (BOOL)confirmCandidateAt:(NSUInteger)index
                  inWindow:(NSData *)window
                needsGrowth:(nullable BOOL *)needsGrowth;

@end

NS_ASSUME_NONNULL_END

#endif
