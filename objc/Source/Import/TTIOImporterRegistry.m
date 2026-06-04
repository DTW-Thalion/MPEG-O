/*
 * TTIOImporterRegistry.m
 * TTI-O Objective-C Implementation
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "Import/TTIOImporterRegistry.h"
#import "Import/TTIOReaderAdapters.h"
#import "Import/TTIOImportedDataset.h"
#import <pthread.h>

// Formats delegated to the dedicated CLIs rather than this registry
// (fasta/fastq keep their richer reference-vs-unaligned CLIs). Mirrors
// Python's importers.registry.CLI_DELEGATED.
static NSArray<NSString *> *_TTIOImportCLIDelegated(void) {
    return @[@"fasta", @"fastq"];
}

static NSError *_TTIOImporterError(NSString *fmt) {
    return [NSError errorWithDomain:@"global.thalion.ttio.ImporterRegistry" code:-1
        userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"unknown import format: %@", fmt]}];
}

@implementation TTIOImporterFormatSpec
- (instancetype)initWithKey:(NSString *)key
                displayName:(NSString *)displayName
                 extensions:(NSArray<NSString *> *)extensions
               requiredTool:(nullable NSString *)requiredTool
                     reader:(id<TTIOReader>)reader {
    if ((self = [super init])) {
        _key = [key copy];
        _displayName = [displayName copy];
        _extensions = [extensions copy];
        _requiredTool = [requiredTool copy];
        _reader = reader;
    }
    return self;
}
@end

static NSDictionary<NSString *, TTIOImporterFormatSpec *> *gByKey = nil;
static NSDictionary<NSString *, NSString *> *gAliases = nil;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

static void _buildImporterRegistry(void) {
    #define SPEC(k, dn, ext, tool, rdr) \
        [[TTIOImporterFormatSpec alloc] initWithKey:(k) displayName:(dn) \
            extensions:(ext) requiredTool:(tool) reader:(rdr)]
    NSArray<TTIOImporterFormatSpec *> *specs = @[
        SPEC(@"mzml", @"mzML", (@[@".mzML", @".mzML.gz"]), nil,
             [[TTIOMzMLReaderAdapter alloc] init]),
        SPEC(@"mztab", @"mzTab", (@[@".mzTab", @".mztab"]), nil,
             [[TTIOMzTabReaderAdapter alloc] init]),
        SPEC(@"imzml", @"imzML", (@[@".imzML"]), nil,
             [[TTIOImzMLReaderAdapter alloc] init]),
        SPEC(@"nmrml", @"nmrML", (@[@".nmrML"]), nil,
             [[TTIONmrMLReaderAdapter alloc] init]),
        SPEC(@"jcamp-dx", @"JCAMP-DX", (@[@".jdx", @".dx", @".jcm"]), nil,
             [[TTIOJcampDxReaderAdapter alloc] init]),
        SPEC(@"bruker-timstof", @"Bruker timsTOF", (@[@".d"]),
             @"Bruker Python helper", [[TTIOBrukerReaderAdapter alloc] init]),
        SPEC(@"waters-masslynx", @"Waters MassLynx", (@[@".raw"]),
             @"masslynxraw", [[TTIOWatersMassLynxReaderAdapter alloc] init]),
        SPEC(@"thermo-raw", @"Thermo .raw", (@[@".raw"]),
             @"ThermoRawFileParser", [[TTIOThermoRawReaderAdapter alloc] init]),
        SPEC(@"bam", @"BAM", (@[@".bam"]), @"samtools",
             [[TTIOBamReaderAdapter alloc] init]),
        SPEC(@"sam", @"SAM", (@[@".sam"]), @"samtools",
             [[TTIOSamReaderAdapter alloc] init]),
        SPEC(@"cram", @"CRAM", (@[@".cram"]), @"samtools",
             [[TTIOCramReaderAdapter alloc] init]),
    ];
    #undef SPEC
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    for (TTIOImporterFormatSpec *s in specs) byKey[s.key] = s;
    gByKey = [byKey copy];

    gAliases = @{
        @"thermo": @"thermo-raw",
        @"thermo.raw": @"thermo-raw",
        @"raw": @"thermo-raw",
        @"waters": @"waters-masslynx",
        @"masslynx": @"waters-masslynx",
        @"bruker": @"bruker-timstof",
        @"timstof": @"bruker-timstof",
        @"tdf": @"bruker-timstof",
        @"jcamp": @"jcamp-dx",
        @"jdx": @"jcamp-dx",
        @"dx": @"jcamp-dx",
        @"jcm": @"jcamp-dx",
    };
}

@implementation TTIOImporterRegistry

+ (NSString *)normalizeFormat:(NSString *)format {
    pthread_once(&gOnce, _buildImporterRegistry);
    NSString *key = [[(format ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        lowercaseString];
    return gAliases[key] ?: key;
}

+ (BOOL)isRegistryFormat:(NSString *)format {
    pthread_once(&gOnce, _buildImporterRegistry);
    return gByKey[[self normalizeFormat:format]] != nil;
}

+ (nullable TTIOImporterFormatSpec *)specForFormat:(NSString *)format
                                             error:(NSError *_Nullable *_Nullable)error {
    pthread_once(&gOnce, _buildImporterRegistry);
    TTIOImporterFormatSpec *spec = gByKey[[self normalizeFormat:format]];
    if (!spec) {
        if (error) *error = _TTIOImporterError(format);
        return nil;
    }
    return spec;
}

+ (NSArray<NSString *> *)registryKeys {
    pthread_once(&gOnce, _buildImporterRegistry);
    return [gByKey.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSString *> *)supportedEncodeFormats {
    pthread_once(&gOnce, _buildImporterRegistry);
    NSMutableSet *all = [NSMutableSet setWithArray:gByKey.allKeys];
    [all addObjectsFromArray:_TTIOImportCLIDelegated()];
    return [all.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

+ (BOOL)encodeFormat:(NSString *)format
              inputs:(NSArray<NSString *> *)inputs
              output:(NSString *)output
             options:(NSDictionary<NSString *, id> *)options
               error:(NSError *_Nullable *_Nullable)error {
    TTIOImporterFormatSpec *spec = [self specForFormat:format error:error];
    if (!spec) return NO;
    TTIOImportedDataset *draft =
        [spec.reader readInputs:inputs
                        options:(options ?: @{})
                       progress:nil
                          error:error];
    if (!draft) return NO;
    return [draft writeToPath:output error:error];
}

@end
