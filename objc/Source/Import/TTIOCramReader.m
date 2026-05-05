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
#include <sys/stat.h>
#include <string.h>
#include <time.h>

// ── Install help text mirrors the M87 BamReader copy. Tests assert on
// the apt/brew/conda hint substrings.
static NSString *const kTTIOCramSamtoolsInstallHelp =
    @"samtools is required by TTIOCramReader but was not found on PATH. "
    @"Install it via your platform's package manager:\n"
    @"  Debian/Ubuntu: apt install samtools\n"
    @"  macOS:         brew install samtools\n"
    @"  Conda:         conda install -c bioconda samtools\n"
    @"Then re-run.";

static NSString *cramFindOnPath(NSString *exe)
{
    NSString *path = [[NSProcessInfo processInfo] environment][@"PATH"];
    if (path.length == 0) return nil;
    NSArray *parts = [path componentsSeparatedByString:@":"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in parts) {
        if (dir.length == 0) continue;
        NSString *full = [dir stringByAppendingPathComponent:exe];
        if ([fm isExecutableFileAtPath:full]) return full;
    }
    return nil;
}

static BOOL cramSamtoolsAvailable(NSString **outBinary, NSError **error)
{
    NSString *bin = cramFindOnPath(@"samtools");
    if (!bin) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen, @"%@",
                                          kTTIOCramSamtoolsInstallHelp);
        return NO;
    }
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = bin;
    task.arguments = @[@"--version"];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError  = out;
    @try {
        [task launch];
    } @catch (NSException *exc) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"%@\n(invocation failed: %@)",
            kTTIOCramSamtoolsInstallHelp, exc.reason ?: @"unknown");
        return NO;
    }
    [task waitUntilExit];
    [[out fileHandleForReading] readDataToEndOfFile];
    if (task.terminationStatus != 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"%@\n(samtools --version exited %d)",
            kTTIOCramSamtoolsInstallHelp, task.terminationStatus);
        return NO;
    }
    if (outBinary) *outBinary = bin;
    return YES;
}

static NSArray<NSString *> *cramSplitTabsLimited(NSString *line, NSUInteger maxFields)
{
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    NSUInteger len = line.length;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [line characterAtIndex:i];
        if (c != '\t') continue;
        if (fields.count + 1 >= maxFields) break;
        [fields addObject:[line substringWithRange:NSMakeRange(start, i - start)]];
        start = i + 1;
    }
    [fields addObject:[line substringFromIndex:start]];
    return fields;
}

static NSDictionary<NSString *, NSString *> *cramParseHeaderFields(NSString *line)
{
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSArray *tokens = [line componentsSeparatedByString:@"\t"];
    for (NSUInteger i = 1; i < tokens.count; i++) {
        NSString *tok = tokens[i];
        NSRange colon = [tok rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [tok substringToIndex:colon.location];
        NSString *val = [tok substringFromIndex:colon.location + 1];
        fields[key] = val;
    }
    return fields;
}

@interface TTIOBamReader ()
@property (nonatomic, readwrite, copy) NSArray<TTIOProvenanceRecord *> *provenanceRecords;
@end

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

- (nullable TTIOWrittenGenomicRun *)toGenomicRunWithName:(nullable NSString *)name
                                                   region:(nullable NSString *)region
                                               sampleName:(nullable NSString *)sampleName
                                                    error:(NSError **)error
{
    (void)name;

    NSString *samtoolsBin = nil;
    if (!cramSamtoolsAvailable(&samtoolsBin, error)) {
        return nil;
    }

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

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = samtoolsBin;
    task.arguments = args;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = errPipe;

    @try {
        [task launch];
    } @catch (NSException *exc) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"failed to launch samtools: %@ (%@)",
            samtoolsBin, exc.reason ?: @"unknown");
        return nil;
    }

    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        NSString *errText = [[NSString alloc] initWithData:errData
                                                   encoding:NSUTF8StringEncoding] ?: @"";
        errText = [errText stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"samtools view exited %d for %@: %@",
            task.terminationStatus, self.path,
            errText.length ? errText : @"(no stderr)");
        return nil;
    }

    NSString *samText = [[NSString alloc] initWithData:outData
                                              encoding:NSUTF8StringEncoding];
    if (!samText) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"samtools output not valid UTF-8 for %@", self.path);
        return nil;
    }

    int64_t fileMtime = 0;
    {
        struct stat st;
        if (stat([self.path fileSystemRepresentation], &st) == 0) {
            fileMtime = (int64_t)st.st_mtime;
        } else {
            fileMtime = (int64_t)time(NULL);
        }
    }

    NSMutableArray<NSString *> *sqNames = [NSMutableArray array];
    NSMutableArray<TTIOProvenanceRecord *> *provenance = [NSMutableArray array];
    NSString *rgSample   = @"";
    NSString *rgPlatform = @"";

    NSMutableArray<NSString *> *readNames        = [NSMutableArray array];
    NSMutableArray<NSString *> *chromosomes      = [NSMutableArray array];
    NSMutableArray<NSString *> *cigars           = [NSMutableArray array];
    NSMutableArray<NSString *> *mateChromosomes  = [NSMutableArray array];
    NSMutableData *positionsData       = [NSMutableData data];
    NSMutableData *mappingQualitiesData = [NSMutableData data];
    NSMutableData *flagsData           = [NSMutableData data];
    NSMutableData *offsetsData         = [NSMutableData data];
    NSMutableData *lengthsData         = [NSMutableData data];
    NSMutableData *matePositionsData   = [NSMutableData data];
    NSMutableData *templateLengthsData = [NSMutableData data];
    NSMutableData *sequencesData       = [NSMutableData data];
    NSMutableData *qualitiesData       = [NSMutableData data];
    uint64_t runningOffset = 0;

    NSArray<NSString *> *lines = [samText componentsSeparatedByString:@"\n"];
    NSUInteger lineNo = 0;
    for (NSString *line in lines) {
        lineNo++;
        if (line.length == 0) continue;
        if ([line hasPrefix:@"@"]) {
            if ([line hasPrefix:@"@SQ"]) {
                NSDictionary *f = cramParseHeaderFields(line);
                NSString *sn = f[@"SN"];
                if (sn.length > 0) [sqNames addObject:sn];
            } else if ([line hasPrefix:@"@RG"]) {
                NSDictionary *f = cramParseHeaderFields(line);
                NSString *sm = f[@"SM"];
                NSString *pl = f[@"PL"];
                if (rgSample.length == 0 && sm.length > 0) rgSample = sm;
                if (rgPlatform.length == 0 && pl.length > 0) rgPlatform = pl;
            } else if ([line hasPrefix:@"@PG"]) {
                NSDictionary *f = cramParseHeaderFields(line);
                NSString *program = f[@"PN"] ?: @"";
                NSString *commandLine = f[@"CL"];
                NSMutableDictionary *params = [NSMutableDictionary dictionary];
                if (commandLine.length > 0) params[@"CL"] = commandLine;
                for (NSString *k in @[@"ID", @"VN", @"PP"]) {
                    NSString *v = f[k];
                    if (v.length > 0) params[k] = v;
                }
                TTIOProvenanceRecord *pg = [[TTIOProvenanceRecord alloc]
                    initWithInputRefs:@[]
                             software:program
                           parameters:params
                           outputRefs:@[]
                        timestampUnix:fileMtime];
                [provenance addObject:pg];
            }
            continue;
        }

        NSArray<NSString *> *cols = cramSplitTabsLimited(line, 12);
        if (cols.count < 11) {
            if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
                @"Malformed SAM alignment at line %lu: expected >=11 "
                @"tab-separated fields, got %lu",
                (unsigned long)lineNo, (unsigned long)cols.count);
            return nil;
        }

        NSString *qname  = cols[0];
        NSString *flagS  = cols[1];
        NSString *rname  = cols[2];
        NSString *posS   = cols[3];
        NSString *mapqS  = cols[4];
        NSString *cigar  = cols[5];
        NSString *rnext  = cols[6];
        NSString *pnextS = cols[7];
        NSString *tlenS  = cols[8];
        NSString *seq    = cols[9];
        NSString *qual   = cols[10];

        uint32_t flag = (uint32_t)[flagS longLongValue];
        int64_t  pos  = (int64_t)[posS  longLongValue];
        uint8_t  mapq = (uint8_t)[mapqS intValue];
        int64_t  pnext = (int64_t)[pnextS longLongValue];
        int32_t  tlen  = (int32_t)[tlenS  intValue];

        NSString *expandedRnext = [rnext isEqualToString:@"="] ? rname : rnext;

        [readNames addObject:qname];
        [chromosomes addObject:rname];
        [cigars addObject:cigar];
        [mateChromosomes addObject:expandedRnext];
        [positionsData appendBytes:&pos length:sizeof(int64_t)];
        [flagsData appendBytes:&flag length:sizeof(uint32_t)];
        [mappingQualitiesData appendBytes:&mapq length:sizeof(uint8_t)];
        [matePositionsData appendBytes:&pnext length:sizeof(int64_t)];
        [templateLengthsData appendBytes:&tlen length:sizeof(int32_t)];

        NSData *seqBytes;
        NSData *qualBytes;
        if ([seq isEqualToString:@"*"]) {
            seqBytes = [NSData data];
        } else {
            seqBytes = [seq dataUsingEncoding:NSASCIIStringEncoding] ?: [NSData data];
        }
        if ([qual isEqualToString:@"*"]) {
            if ([seq isEqualToString:@"*"]) {
                qualBytes = [NSData data];
            } else {
                NSMutableData *q = [NSMutableData dataWithLength:seqBytes.length];
                memset(q.mutableBytes, 0xFF, q.length);
                qualBytes = q;
            }
        } else {
            qualBytes = [qual dataUsingEncoding:NSASCIIStringEncoding] ?: [NSData data];
        }

        if (qualBytes.length != seqBytes.length) {
            if ([seq isEqualToString:@"*"]) {
                qualBytes = [NSData data];
            } else if (![qual isEqualToString:@"*"]) {
                if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
                    @"SEQ/QUAL length mismatch at line %lu: "
                    @"SEQ=%lu QUAL=%lu",
                    (unsigned long)lineNo,
                    (unsigned long)seqBytes.length,
                    (unsigned long)qualBytes.length);
                return nil;
            }
        }

        uint64_t offset = runningOffset;
        uint32_t length = (uint32_t)seqBytes.length;
        [offsetsData appendBytes:&offset length:sizeof(uint64_t)];
        [lengthsData appendBytes:&length length:sizeof(uint32_t)];
        [sequencesData appendData:seqBytes];
        [qualitiesData appendData:qualBytes];
        runningOffset += length;
    }

    self.provenanceRecords = provenance;

    NSString *effSample = (sampleName != nil) ? sampleName : rgSample;
    NSString *referenceUri = (sqNames.count > 0) ? sqNames[0] : @"";

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:referenceUri
                       platform:rgPlatform
                     sampleName:effSample
                      positions:positionsData
               mappingQualities:mappingQualitiesData
                          flags:flagsData
                      sequences:sequencesData
                      qualities:qualitiesData
                        offsets:offsetsData
                        lengths:lengthsData
                         cigars:cigars
                      readNames:readNames
                mateChromosomes:mateChromosomes
                  matePositions:matePositionsData
                templateLengths:templateLengthsData
                    chromosomes:chromosomes
              signalCompression:TTIOCompressionZlib];
}

@end
