/*
 * TTIOFastaReader.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOFastaReader
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Import/TTIOFastaReader.h
 *
 * FASTA parser supporting reference and unaligned-run modes. Reads
 * via stdio + zlib so gzip-compressed input is transparent.
 *
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOFastaReader.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "ValueClasses/TTIOEnums.h"

#import <zlib.h>
#import <string.h>


NSString *const TTIOFastaReaderErrorDomain = @"TTIOFastaReaderErrorDomain";


// Forward declaration — exported helper defined below (also reused by
// TTIOFastqReader.m via the same symbol).
TTIOWrittenGenomicRun *TTIOFastaReaderBuildUnalignedRun(
    NSArray<NSString *> *readNames,
    NSData *sequences,
    NSData *qualities,
    NSArray<NSNumber *> *offsetsArr,
    NSArray<NSNumber *> *lengthsArr,
    NSString *sampleName,
    NSString *platform,
    NSString *referenceUri,
    TTIOAcquisitionMode mode);


// SAM unmapped sentinels, matching TTIOBamReader's "QUAL absent" path.
static const uint8_t kUnmappedQualByte = 0xFF;
static const uint32_t kUnmappedFlag    = 4;
static NSString *const kUnmappedChrom  = @"*";
static NSString *const kUnmappedCigar  = @"*";
static const int64_t  kUnmappedPos     = 0;
static const uint8_t  kUnmappedMapq    = 0xFF;


// ---------------------------------------------------------------- gzip helpers

/** Open ``path`` for reading. Always uses gzopen — uncompressed
 *  files are read transparently because gzip detects the magic
 *  bytes itself and falls back to passthrough mode. */
static gzFile open_maybe_gzip(NSString *path)
{
    return gzopen([path fileSystemRepresentation], "rb");
}


// ---------------------------------------------------------------- record iter

/** Read one line from gzipped/plain input into ``buf``. Strips
 *  trailing CR and LF. Returns YES if a line was read (may be
 *  empty), NO at EOF. */
static BOOL read_line(gzFile fh, NSMutableData *buf)
{
    [buf setLength:0];
    char ch;
    int n;
    while ((n = gzread(fh, &ch, 1)) > 0) {
        if (ch == '\n') return YES;
        if (ch == '\r') continue;
        [buf appendBytes:&ch length:1];
    }
    return buf.length > 0; // YES if we read partial trailing line, NO if EOF on empty
}

/** Parse a FASTA header line ``>name [desc]`` — returns the name
 *  token (first whitespace-delimited token after ``>``). Returns
 *  ``nil`` if the line has no name. */
static NSString *parse_header(NSData *line)
{
    const uint8_t *bytes = line.bytes;
    NSUInteger len = line.length;
    if (len < 1 || bytes[0] != '>') return nil;
    NSUInteger i = 1;
    while (i < len && (bytes[i] == ' ' || bytes[i] == '\t')) i++;
    NSUInteger start = i;
    while (i < len && bytes[i] != ' ' && bytes[i] != '\t') i++;
    if (i == start) return nil;
    return [[NSString alloc] initWithBytes:bytes + start
                                    length:i - start
                                  encoding:NSUTF8StringEncoding];
}

/** Iterate FASTA records, invoking ``block`` for each
 *  ``(name, sequence_bytes)`` pair. Returns NO with ``error`` set
 *  on a malformed input. */
static BOOL iterate_records(gzFile fh,
                            NSError **error,
                            void (^block)(NSString *name, NSData *seq))
{
    NSMutableData *line = [NSMutableData dataWithCapacity:128];
    NSString *currentName = nil;
    NSMutableData *currentSeq = [NSMutableData dataWithCapacity:1024];

    while (1) {
        BOOL more = read_line(fh, line);
        if (!more && line.length == 0) break;
        const uint8_t *bytes = line.bytes;
        if (line.length > 0 && bytes[0] == '>') {
            if (currentName != nil) {
                block(currentName, [currentSeq copy]);
                [currentSeq setLength:0];
            }
            NSString *name = parse_header(line);
            if (name == nil) {
                if (error) {
                    *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                                 code:TTIOFastaReaderErrorParseFailed
                                             userInfo:@{ NSLocalizedDescriptionKey :
                                                         @"FASTA header missing a name token (line starts with '>')" }];
                }
                return NO;
            }
            currentName = name;
        } else if (line.length > 0) {
            if (currentName == nil) {
                if (error) {
                    *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                                 code:TTIOFastaReaderErrorParseFailed
                                             userInfo:@{ NSLocalizedDescriptionKey :
                                                         @"FASTA sequence bytes encountered before any header line" }];
                }
                return NO;
            }
            [currentSeq appendData:line];
        }
        if (!more) break;
    }
    if (currentName != nil) {
        block(currentName, [currentSeq copy]);
    }
    return YES;
}


// ---------------------------------------------------------------- helpers

/** Strip ".gz" / ".fa" / ".fasta" / ".fna" / ".fq" / ".fastq"
 *  suffixes from a filename to produce a URI stem. */
static NSString *derive_uri(NSString *path)
{
    NSString *name = [path lastPathComponent];
    NSString *lower = [name lowercaseString];
    if ([lower hasSuffix:@".gz"]) {
        name = [name substringToIndex:name.length - 3];
        lower = [name lowercaseString];
    }
    NSArray<NSString *> *exts = @[ @".fasta", @".fastq", @".fna", @".fa", @".fq" ];
    for (NSString *ext in exts) {
        if ([lower hasSuffix:ext]) {
            name = [name substringToIndex:name.length - ext.length];
            break;
        }
    }
    return name;
}


// ---------------------------------------------------------------- public API

@implementation TTIOFastaReader

+ (TTIOReferenceImport *)readReferenceFromPath:(NSString *)path
                                            uri:(NSString *)uri
                                          error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                         code:TTIOFastaReaderErrorMissingFile
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"FASTA file not found: %@", path] }];
        }
        return nil;
    }
    gzFile fh = open_maybe_gzip(path);
    if (fh == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                         code:TTIOFastaReaderErrorMissingFile
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"could not open %@", path] }];
        }
        return nil;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSData *> *seqs = [NSMutableArray array];
    BOOL ok = iterate_records(fh, error, ^(NSString *name, NSData *seq) {
        [names addObject:name];
        [seqs addObject:seq];
    });
    gzclose(fh);
    if (!ok) return nil;

    if (names.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                         code:TTIOFastaReaderErrorEmptyInput
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"no FASTA records found in %@", path] }];
        }
        return nil;
    }

    NSString *effectiveUri = (uri != nil) ? uri : derive_uri(path);
    return [[TTIOReferenceImport alloc] initWithUri:effectiveUri
                                        chromosomes:names
                                          sequences:seqs];
}

+ (TTIOWrittenGenomicRun *)readUnalignedFromPath:(NSString *)path
                                       sampleName:(NSString *)sampleName
                                         platform:(NSString *)platform
                                     referenceUri:(NSString *)referenceUri
                                  acquisitionMode:(TTIOAcquisitionMode)mode
                                            error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                         code:TTIOFastaReaderErrorMissingFile
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"FASTA file not found: %@", path] }];
        }
        return nil;
    }
    gzFile fh = open_maybe_gzip(path);
    if (fh == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                         code:TTIOFastaReaderErrorMissingFile
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"could not open %@", path] }];
        }
        return nil;
    }

    NSMutableArray<NSString *> *readNames = [NSMutableArray array];
    NSMutableData *seqBuf = [NSMutableData dataWithCapacity:1024];
    NSMutableData *qualBuf = [NSMutableData dataWithCapacity:1024];
    NSMutableArray<NSNumber *> *offsetsArr = [NSMutableArray array];
    NSMutableArray<NSNumber *> *lengthsArr = [NSMutableArray array];
    __block uint64_t running = 0;

    BOOL ok = iterate_records(fh, error, ^(NSString *name, NSData *seq) {
        [readNames addObject:name];
        [offsetsArr addObject:@(running)];
        [lengthsArr addObject:@((uint32_t)seq.length)];
        [seqBuf appendData:seq];
        // Fill qualities with the unmapped sentinel byte.
        NSUInteger n = seq.length;
        if (n > 0) {
            uint8_t *fill = malloc(n);
            memset(fill, kUnmappedQualByte, n);
            [qualBuf appendBytes:fill length:n];
            free(fill);
        }
        running += (uint64_t)seq.length;
    });
    gzclose(fh);
    if (!ok) return nil;

    if (readNames.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFastaReaderErrorDomain
                                         code:TTIOFastaReaderErrorEmptyInput
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                 [NSString stringWithFormat:@"no FASTA records found in %@", path] }];
        }
        return nil;
    }

    return TTIOFastaReaderBuildUnalignedRun(
        readNames, seqBuf, qualBuf, offsetsArr, lengthsArr,
        sampleName, platform, referenceUri, mode
    );
}

@end


// ---------------------------------------------------------------- shared
//
// Public C function so TTIOFastqReader can call it without subclassing.
// Builds the WrittenGenomicRun from per-read accumulators and the
// concatenated SEQ / QUAL byte buffers.

TTIOWrittenGenomicRun *TTIOFastaReaderBuildUnalignedRun(
    NSArray<NSString *> *readNames,
    NSData *sequences,
    NSData *qualities,
    NSArray<NSNumber *> *offsetsArr,
    NSArray<NSNumber *> *lengthsArr,
    NSString *sampleName,
    NSString *platform,
    NSString *referenceUri,
    TTIOAcquisitionMode mode)
{
    NSUInteger n = readNames.count;
    int64_t  *positions       = malloc(n * sizeof(int64_t));
    uint8_t  *mappingQual     = malloc(n * sizeof(uint8_t));
    uint32_t *flags           = malloc(n * sizeof(uint32_t));
    uint64_t *offsets         = malloc(n * sizeof(uint64_t));
    uint32_t *lengths         = malloc(n * sizeof(uint32_t));
    int64_t  *matePositions   = malloc(n * sizeof(int64_t));
    int32_t  *templateLengths = malloc(n * sizeof(int32_t));
    NSMutableArray<NSString *> *cigars = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *mateChroms = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *chroms = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        positions[i] = kUnmappedPos;
        mappingQual[i] = kUnmappedMapq;
        flags[i] = kUnmappedFlag;
        offsets[i] = (uint64_t)offsetsArr[i].unsignedLongLongValue;
        lengths[i] = (uint32_t)lengthsArr[i].unsignedIntValue;
        matePositions[i] = -1;
        templateLengths[i] = 0;
        [cigars addObject:kUnmappedCigar];
        [mateChroms addObject:kUnmappedChrom];
        [chroms addObject:kUnmappedChrom];
    }

    NSData *positionsData = [NSData dataWithBytesNoCopy:positions length:n * sizeof(int64_t) freeWhenDone:YES];
    NSData *mapqData = [NSData dataWithBytesNoCopy:mappingQual length:n freeWhenDone:YES];
    NSData *flagsData = [NSData dataWithBytesNoCopy:flags length:n * sizeof(uint32_t) freeWhenDone:YES];
    NSData *offsetsData = [NSData dataWithBytesNoCopy:offsets length:n * sizeof(uint64_t) freeWhenDone:YES];
    NSData *lengthsData = [NSData dataWithBytesNoCopy:lengths length:n * sizeof(uint32_t) freeWhenDone:YES];
    NSData *mpData = [NSData dataWithBytesNoCopy:matePositions length:n * sizeof(int64_t) freeWhenDone:YES];
    NSData *tlData = [NSData dataWithBytesNoCopy:templateLengths length:n * sizeof(int32_t) freeWhenDone:YES];

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:mode
                   referenceUri:referenceUri ?: @""
                       platform:platform ?: @""
                     sampleName:sampleName ?: @""
                      positions:positionsData
               mappingQualities:mapqData
                          flags:flagsData
                      sequences:sequences
                      qualities:qualities
                        offsets:offsetsData
                        lengths:lengthsData
                         cigars:cigars
                      readNames:readNames
                mateChromosomes:mateChroms
                  matePositions:mpData
                templateLengths:tlData
                    chromosomes:chroms
              signalCompression:TTIOCompressionZlib];
}
