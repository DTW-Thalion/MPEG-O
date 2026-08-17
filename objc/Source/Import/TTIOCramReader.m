/*
 * TTIOCramReader.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOCramReader
 * Inherits From: TTIOBamReader : NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Import/TTIOCramReader.h
 *
 * CRAM importer. Subclass of TTIOBamReader with a required
 * reference-FASTA argument; injects --reference into the samtools
 * view command line so the reference-compressed sequence bytes can
 * be decoded.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOCramReader.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOCramReader

// NS_UNAVAILABLE in the header documents intent for clients; the
// inherited implementation is still emitted for binary compat.
- (instancetype)initWithPath:(NSString *)path
{
    return [super initWithPath:path];
}

- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta
{
    self = [super initWithPath:path];
    if (self) {
        _referenceFasta = [referenceFasta copy];
    }
    return self;
}

- (NSArray<NSString *> *)samtoolsArgumentsForRegion:(NSString *)region error:(NSError **)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:self.path]) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound,
            @"CRAM file not found: %@", self.path);
        return nil;
    }
    if (![fm fileExistsAtPath:_referenceFasta]) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound,
            @"Reference FASTA not found: %@", _referenceFasta);
        return nil;
    }
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
        @"view", @"-h",
        @"--reference", _referenceFasta,
        self.path, nil];
    if (region.length > 0) [args addObject:region];
    return args;
}

@end
