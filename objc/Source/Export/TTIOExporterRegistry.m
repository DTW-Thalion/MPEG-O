/*
 * TTIOExporterRegistry.m
 * TTI-O Objective-C Implementation
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "Export/TTIOExporterRegistry.h"
#import "Export/TTIOWriterAdapters.h"
#import "Dataset/TTIOSpectralDataset.h"
#import <pthread.h>

// Formats delegated to the dedicated CLIs rather than this registry.
// Mirrors Python's exporters.registry.CLI_DELEGATED.
static NSArray<NSString *> *_TTIOExportCLIDelegated(void) {
    return @[@"fasta", @"fastq"];
}

static NSError *_TTIOExporterError(NSString *fmt) {
    return [NSError errorWithDomain:@"global.thalion.ttio.ExporterRegistry" code:-1
        userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"unknown export format: %@", fmt]}];
}

@implementation TTIOExporterFormatSpec
- (instancetype)initWithKey:(NSString *)key
                displayName:(NSString *)displayName
                 extensions:(NSArray<NSString *> *)extensions
               requiredTool:(nullable NSString *)requiredTool
                     writer:(id<TTIOWriter>)writer {
    if ((self = [super init])) {
        _key = [key copy];
        _displayName = [displayName copy];
        _extensions = [extensions copy];
        _requiredTool = [requiredTool copy];
        _writer = writer;
    }
    return self;
}
@end

static NSDictionary<NSString *, TTIOExporterFormatSpec *> *gByKey = nil;
static NSDictionary<NSString *, NSString *> *gAliases = nil;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

static void _buildExporterRegistry(void) {
    #define SPEC(k, dn, ext, tool, wtr) \
        [[TTIOExporterFormatSpec alloc] initWithKey:(k) displayName:(dn) \
            extensions:(ext) requiredTool:(tool) writer:(wtr)]
    NSArray<TTIOExporterFormatSpec *> *specs = @[
        SPEC(@"mzml", @"mzML", (@[@".mzML"]), nil,
             [[TTIOMzMLWriterAdapter alloc] init]),
        SPEC(@"mztab", @"mzTab", (@[@".mzTab", @".mztab"]), nil,
             [[TTIOMzTabWriterAdapter alloc] init]),
        SPEC(@"nmrml", @"nmrML", (@[@".nmrML"]), nil,
             [[TTIONmrMLWriterAdapter alloc] init]),
        SPEC(@"imzml", @"imzML", (@[@".imzML"]), nil,
             [[TTIOImzMLWriterAdapter alloc] init]),
        SPEC(@"jcamp-dx", @"JCAMP-DX", (@[@".jdx", @".dx", @".jcm"]), nil,
             [[TTIOJcampDxWriterAdapter alloc] init]),
        SPEC(@"isa", @"ISA-Tab/JSON", (@[@".zip", @".json"]), nil,
             [[TTIOIsaWriterAdapter alloc] init]),
        SPEC(@"bam", @"BAM", (@[@".bam", @".sam"]), @"samtools",
             [[TTIOBamWriterAdapter alloc] init]),
        SPEC(@"cram", @"CRAM", (@[@".cram"]), @"samtools",
             [[TTIOCramWriterAdapter alloc] init]),
    ];
    #undef SPEC
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    for (TTIOExporterFormatSpec *s in specs) byKey[s.key] = s;
    gByKey = [byKey copy];

    gAliases = @{
        @"isa-tab": @"isa",
        @"isatab": @"isa",
        @"jcamp": @"jcamp-dx",
        @"jdx": @"jcamp-dx",
        @"dx": @"jcamp-dx",
        @"jcm": @"jcamp-dx",
    };
}

@implementation TTIOExporterRegistry

+ (NSString *)normalizeFormat:(NSString *)format {
    pthread_once(&gOnce, _buildExporterRegistry);
    NSString *key = [[(format ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        lowercaseString];
    return gAliases[key] ?: key;
}

+ (BOOL)isRegistryFormat:(NSString *)format {
    pthread_once(&gOnce, _buildExporterRegistry);
    return gByKey[[self normalizeFormat:format]] != nil;
}

+ (nullable TTIOExporterFormatSpec *)specForFormat:(NSString *)format
                                             error:(NSError *_Nullable *_Nullable)error {
    pthread_once(&gOnce, _buildExporterRegistry);
    TTIOExporterFormatSpec *spec = gByKey[[self normalizeFormat:format]];
    if (!spec) {
        if (error) *error = _TTIOExporterError(format);
        return nil;
    }
    return spec;
}

+ (NSArray<NSString *> *)registryKeys {
    pthread_once(&gOnce, _buildExporterRegistry);
    return [gByKey.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSString *> *)supportedExportFormats {
    pthread_once(&gOnce, _buildExporterRegistry);
    NSMutableSet *all = [NSMutableSet setWithArray:gByKey.allKeys];
    [all addObjectsFromArray:_TTIOExportCLIDelegated()];
    return [all.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

+ (BOOL)exportFormat:(NSString *)format
             tioPath:(NSString *)tioPath
               layer:(nullable NSString *)layer
              output:(NSString *)output
             options:(NSDictionary<NSString *, id> *)options
               error:(NSError *_Nullable *_Nullable)error {
    TTIOExporterFormatSpec *spec = [self specForFormat:format error:error];
    if (!spec) return NO;
    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:tioPath error:error];
    if (!ds) return NO;
    BOOL ok = [spec.writer writeDataset:ds
                                 layer:layer
                              toOutput:output
                               options:(options ?: @{})
                                 error:error];
    [ds closeFile];
    return ok;
}

@end
