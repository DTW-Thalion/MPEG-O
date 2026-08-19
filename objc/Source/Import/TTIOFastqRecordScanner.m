/* SPDX-License-Identifier: LGPL-3.0-or-later */
#import "Import/TTIOFastqRecordScanner.h"

static const NSUInteger kScanWindowInitial = 1u << 20;
static const NSUInteger kScanWindowMax     = 16u << 20;

@implementation TTIOFastqRecordScanner

+ (BOOL)confirmCandidateAt:(NSUInteger)index
                  inWindow:(NSData *)window
               needsGrowth:(BOOL *)needsGrowth
{
    if (needsGrowth) *needsGrowth = NO;
    const uint8_t *b = window.bytes;
    NSUInteger n = window.length;
    if (index >= n || b[index] != '@') return NO;
    /* End of the header line. */
    NSUInteger i = index;
    while (i < n && b[i] != '\n') i++;
    if (i >= n) { if (needsGrowth) *needsGrowth = YES; return NO; }
    /* End of the sequence line. */
    NSUInteger j = i + 1;
    while (j < n && b[j] != '\n') j++;
    if (j >= n) { if (needsGrowth) *needsGrowth = YES; return NO; }
    /* The separator line must start with '+'. */
    NSUInteger k = j + 1;
    if (k >= n) { if (needsGrowth) *needsGrowth = YES; return NO; }
    return b[k] == '+';
}

+ (long long)boundaryAtOrAfter:(long long)offset
                        inFile:(NSFileHandle *)fh
                    fileLength:(long long)fileLength
{
    if (offset >= fileLength) return fileLength;
    long long base = offset;
    /* A candidate needs the byte before it unless it is offset 0. */
    if (base > 0) base -= 1;
    NSUInteger windowLen = kScanWindowInitial;
    while (base < fileLength) {
        @autoreleasepool {
            [fh seekToFileOffset:(unsigned long long)base];
            NSData *window = [fh readDataOfLength:windowLen];
            const uint8_t *b = window.bytes;
            NSUInteger n = window.length;
            BOOL grewThisWindow = NO;
            for (NSUInteger i = 0; i < n; i++) {
                long long abs = base + (long long)i;
                if (abs < offset) continue;
                BOOL atStart = (abs == 0 && b[i] == '@');
                BOOL afterNl = (i > 0 && b[i] == '@' && b[i - 1] == '\n');
                if (!atStart && !afterNl) continue;
                BOOL grow = NO;
                if ([self confirmCandidateAt:i inWindow:window needsGrowth:&grow]) {
                    return abs;
                }
                if (grow) {
                    if (base + (long long)n >= fileLength) {
                        /* The file ends inside this record: no further
                         * boundary exists. */
                        return fileLength;
                    }
                    if (windowLen < kScanWindowMax) {
                        windowLen *= 2;
                        grewThisWindow = YES;
                        break;   /* re-read a larger window at base */
                    }
                    /* Pathological line longer than the cap: skip this
                     * candidate and keep scanning. */
                }
            }
            if (grewThisWindow) continue;
            if (base + (long long)n >= fileLength) return fileLength;
            /* Overlap by 1 so a '\n@' pair on the edge is seen. */
            base += (long long)n - 1;
        }
    }
    return fileLength;
}

@end
