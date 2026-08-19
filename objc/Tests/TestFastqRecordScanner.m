/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * TTIOFastqRecordScanner: the shard-mode boundary rule.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Import/TTIOFastqRecordScanner.h"
#include <unistd.h>

static NSString *frsWrite(NSData *body)
{
    NSString *p = [NSString stringWithFormat:@"/tmp/frs-%d.fastq", (int)getpid()];
    [body writeToFile:p atomically:YES];
    return p;
}

static NSData *frsRecord(const char *name, NSString *seq, NSString *qual)
{
    NSMutableData *d = [NSMutableData data];
    [d appendData:[[NSString stringWithFormat:@"@%s\n", name] dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendData:[seq dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendData:[@"\n+\n" dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendData:[qual dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendData:[@"\n" dataUsingEncoding:NSASCIIStringEncoding]];
    return d;
}

void testFastqRecordScanner(void);
void testFastqRecordScanner(void)
{
    // Record 1's quality string STARTS with '@': the false candidate.
    NSMutableData *body = [NSMutableData data];
    NSData *r1 = frsRecord("r1", @"ACGTACGT", @"@IIIIIII");
    NSData *r2 = frsRecord("r2", @"TTTTGGGG", @"IIIIIIII");
    NSData *r3 = frsRecord("r3", @"CCCCAAAA", @"IIIIIIII");
    [body appendData:r1]; [body appendData:r2]; [body appendData:r3];
    NSString *p = frsWrite(body);
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
    long long len = (long long)body.length;
    long long r2at = (long long)r1.length;
    long long r3at = r2at + (long long)r2.length;

    PASS([TTIOFastqRecordScanner boundaryAtOrAfter:0 inFile:fh fileLength:len] == 0,
         "record scanner: offset 0 is a boundary");
    // Offset 1 lands inside record 1; the quality-line '@' of record 1
    // must be rejected and the next true boundary is record 2.
    PASS([TTIOFastqRecordScanner boundaryAtOrAfter:1 inFile:fh fileLength:len] == r2at,
         "record scanner: '@' in a quality line is rejected");
    // From inside record 2 the boundary is record 3.
    PASS([TTIOFastqRecordScanner boundaryAtOrAfter:r2at + 3 inFile:fh fileLength:len] == r3at,
         "record scanner: mid-record offset finds the next record");
    // Inside the final record there is no further boundary.
    PASS([TTIOFastqRecordScanner boundaryAtOrAfter:r3at + 1 inFile:fh fileLength:len] == len,
         "record scanner: no boundary after the last record");
    // Truncated final record: still no boundary, never a hang.
    NSMutableData *trunc = [body mutableCopy];
    trunc.length = body.length - 5;
    NSString *p2 = frsWrite(trunc);
    NSFileHandle *fh2 = [NSFileHandle fileHandleForReadingAtPath:p2];
    PASS([TTIOFastqRecordScanner boundaryAtOrAfter:r3at + 1 inFile:fh2 fileLength:(long long)trunc.length]
             == (long long)trunc.length,
         "record scanner: truncated final record");
    // The exposed validator: growth is requested when the window ends
    // before the '+' line.
    BOOL grow = NO;
    NSData *cut = [r2 subdataWithRange:NSMakeRange(0, 6)];
    PASS(![TTIOFastqRecordScanner confirmCandidateAt:0 inWindow:cut needsGrowth:&grow] && grow,
         "record scanner: short window asks for growth");
    [fh closeFile];
    [fh2 closeFile];
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:p2 error:NULL];
}
