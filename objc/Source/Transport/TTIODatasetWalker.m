/*
 * TTIODatasetWalker.m
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Filtered dataset walker — produces transport-stream events
 * (StreamHeader → DatasetHeaders → AccessUnits → EndOfDataset →
 * EndOfStream) and dispatches them to a visitor. Owners decide what
 * to do with each event: encode as transport packets, build stats
 * records, count matches, etc.
 *
 * The walker is intentionally independent of TTIOTransportWriter —
 * downstream code can drive it without producing any wire bytes.
 */
#import "TTIODatasetWalker.h"

#import "Core/TTIOPortability.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEnums.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "TTIOAUFilter.h"
#import "TTIOAccessUnit.h"

// ---------------------------------------------------------------- helpers

static uint8_t wireFromSpectrumClassName(NSString *name)
{
    if ([name isEqualToString:@"TTIONMRSpectrum"])      return 1;
    if ([name isEqualToString:@"TTIONMR2D"])            return 2;
    if ([name isEqualToString:@"TTIOFID"])              return 3;
    if ([name isEqualToString:@"TTIOMSImagePixel"])     return 4;
    if ([name isEqualToString:@"TTIOGenomicRead"])      return 5;
    return 0;  // TTIOMassSpectrum / default
}

static uint8_t wireFromPolarity(TTIOPolarity p)
{
    switch (p) {
        case TTIOPolarityPositive: return 0;
        case TTIOPolarityNegative: return 1;
        case TTIOPolarityUnknown:
        default:                   return 2;
    }
}

static NSString *instrumentConfigJSON(TTIOInstrumentConfig *cfg)
{
    if (!cfg) return @"{}";
    // Mirrors the field set produced by
    // TTIOTransportWriter.m's instrumentConfigJSON so the
    // visitor-driven walk emits byte-identical dataset headers.
    NSDictionary *d = @{
        @"analyzer_type": cfg.analyzerType ?: @"",
        @"detector_type": cfg.detectorType ?: @"",
        @"manufacturer":  cfg.manufacturer ?: @"",
        @"model":         cfg.model        ?: @"",
        @"serial_number": cfg.serialNumber ?: @"",
        @"source_type":   cfg.sourceType   ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                    options:TTIO_JSON_SORTED_KEYS
                                                      error:NULL];
    return data
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"{}";
}

static NSString *genomicRunMetadataJSON(TTIOGenomicRun *run)
{
    if (!run) return @"{}";
    NSDictionary *d = @{
        @"modality":      run.modality      ?: @"",
        @"platform":      run.platform      ?: @"",
        @"reference_uri": run.referenceUri  ?: @"",
        @"sample_name":   run.sampleName    ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                    options:TTIO_JSON_SORTED_KEYS
                                                      error:NULL];
    return data
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"{}";
}

static TTIOAccessUnit *accessUnitFromSpectrum(TTIOSpectrum *spectrum,
                                                TTIOAcquisitionRun *run,
                                                NSArray<NSString *> *channelNames)
{
    uint8_t wireClass = wireFromSpectrumClassName(run.spectrumClassName);
    uint8_t msLevel = 0;
    uint8_t polarityWire = 2;
    if ([spectrum isKindOfClass:[TTIOMassSpectrum class]]) {
        TTIOMassSpectrum *ms = (TTIOMassSpectrum *)spectrum;
        msLevel = (uint8_t)MIN((NSUInteger)255, ms.msLevel);
        polarityWire = wireFromPolarity(ms.polarity);
    }
    double bpi = 0.0;
    if (run.spectrumIndex && spectrum.indexPosition < run.spectrumIndex.count) {
        bpi = [run.spectrumIndex basePeakIntensityAt:spectrum.indexPosition];
    }
    NSMutableArray<TTIOTransportChannelData *> *channels = [NSMutableArray array];
    for (NSString *cname in channelNames) {
        TTIOSignalArray *sa = spectrum.signalArrays[cname];
        if (!sa) continue;
        NSData *raw = sa.buffer ?: [NSData data];
        uint32_t nElements = (uint32_t)(raw.length / 8);
        TTIOTransportChannelData *ch =
            [[TTIOTransportChannelData alloc]
                initWithName:cname
                   precision:TTIOPrecisionFloat64
                 compression:TTIOCompressionNone
                   nElements:nElements
                        data:raw];
        [channels addObject:ch];
    }
    return [[TTIOAccessUnit alloc]
        initWithSpectrumClass:wireClass
                acquisitionMode:(uint8_t)run.acquisitionMode
                        msLevel:msLevel
                       polarity:polarityWire
                  retentionTime:spectrum.scanTimeSeconds
                    precursorMz:spectrum.precursorMz
                precursorCharge:(uint8_t)MIN((NSUInteger)255, spectrum.precursorCharge)
                    ionMobility:0.0
              basePeakIntensity:bpi
                       channels:channels
                         pixelX:0 pixelY:0 pixelZ:0];
}

// ---------------------------------------------------------------- walker

@implementation TTIODatasetWalker

- (BOOL)walkDataset:(TTIOSpectralDataset *)dataset
              filter:(TTIOAUFilter *)filter
             visitor:(id<TTIOTransportEventVisitor>)visitor
               error:(NSError **)error
{
    (void)error;  // No structural errors today; reserved for future.
    if (!dataset || !visitor) return NO;

    NSArray<NSString *> *msNames = [dataset.msRuns.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSString *> *gNames = [dataset.genomicRuns.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger nDatasets = msNames.count + gNames.count;

    // ── 1. StreamHeader ────────────────────────────────────────────
    if ([visitor respondsToSelector:
            @selector(walker:visitStreamHeaderWithFormatVersion:title:isaInvestigation:features:nDatasets:)]) {
        [visitor walker:self
visitStreamHeaderWithFormatVersion:@"1.2"
                                title:dataset.title ?: @""
                     isaInvestigation:dataset.isaInvestigationId ?: @""
                             features:@[]
                           nDatasets:(uint16_t)nDatasets];
    }

    // ── 2. DatasetHeaders (MS runs first, then genomic) ────────────
    uint16_t did = 1;
    NSNumber *filterDid = filter.datasetId;
    for (NSString *name in msNames) {
        if (filterDid && did != filterDid.unsignedIntValue) {
            did++;
            continue;
        }
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        NSArray<NSString *> *channelNames =
            [run valueForKey:@"channelNames"] ?: @[@"mz", @"intensity"];
        if ([visitor respondsToSelector:
                @selector(walker:visitDatasetHeaderWithDatasetId:name:acquisitionMode:spectrumClass:channelNames:instrumentJSON:expectedAUCount:)]) {
            [visitor walker:self
visitDatasetHeaderWithDatasetId:did
                                  name:name
                       acquisitionMode:(uint8_t)run.acquisitionMode
                         spectrumClass:run.spectrumClassName ?: @"TTIOMassSpectrum"
                          channelNames:channelNames
                        instrumentJSON:instrumentConfigJSON(run.instrumentConfig)
                      expectedAUCount:(uint32_t)[run count]];
        }
        did++;
    }
    NSArray<NSString *> *gChannelNames = @[@"sequences", @"qualities",
                                            @"cigar", @"read_name",
                                            @"mate_chromosome"];
    for (NSString *name in gNames) {
        if (filterDid && did != filterDid.unsignedIntValue) {
            did++;
            continue;
        }
        TTIOGenomicRun *grun = dataset.genomicRuns[name];
        if ([visitor respondsToSelector:
                @selector(walker:visitDatasetHeaderWithDatasetId:name:acquisitionMode:spectrumClass:channelNames:instrumentJSON:expectedAUCount:)]) {
            [visitor walker:self
visitDatasetHeaderWithDatasetId:did
                                  name:name
                       acquisitionMode:(uint8_t)grun.acquisitionMode
                         spectrumClass:@"TTIOGenomicRead"
                          channelNames:gChannelNames
                        instrumentJSON:genomicRunMetadataJSON(grun)
                      expectedAUCount:(uint32_t)grun.readCount];
        }
        did++;
    }

    // ── 3. AccessUnits ────────────────────────────────────────────
    uint32_t emitted = 0;
    uint32_t maxAU = filter.maxAU ? filter.maxAU.unsignedIntValue : UINT32_MAX;
    did = 1;
    BOOL hasAccessUnitVisitor = [visitor respondsToSelector:
        @selector(walker:visitAccessUnit:datasetId:auSequence:)];

    for (NSString *name in msNames) {
        if (filterDid && did != filterDid.unsignedIntValue) {
            did++;
            continue;
        }
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        NSArray<NSString *> *channelNames =
            [run valueForKey:@"channelNames"] ?: @[@"mz", @"intensity"];
        NSUInteger count = [run count];
        for (NSUInteger i = 0; i < count && emitted < maxAU; i++) {
            TTIOSpectrum *sp = [run objectAtIndex:i];
            TTIOAccessUnit *au =
                accessUnitFromSpectrum(sp, run, channelNames);
            if (filter && ![filter matches:au datasetId:did]) continue;
            if (hasAccessUnitVisitor) {
                [visitor walker:self
             visitAccessUnit:au
                   datasetId:did
                  auSequence:(uint32_t)i];
            }
            emitted++;
        }
        did++;
        if (emitted >= maxAU) break;
    }
    // (Genomic AU emission is intentionally not yet wired here — the
    //  workbench server's S3 MVP targets MS + non-genomic predicates
    //  first. Genomic walking is a Phase 2 follow-up; the walker's
    //  protocol surface already supports it.)
    did = (uint16_t)(msNames.count + 1);
    (void)did;  // suppress unused-variable warning until genomic
                // emission lands.

    // ── 4. EndOfDataset per dataset ────────────────────────────────
    did = 1;
    BOOL hasEodVisitor = [visitor respondsToSelector:
        @selector(walker:visitEndOfDatasetWithDatasetId:finalAUSequence:)];
    for (NSString *name in msNames) {
        if (filterDid && did != filterDid.unsignedIntValue) {
            did++;
            continue;
        }
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        if (hasEodVisitor) {
            [visitor walker:self
visitEndOfDatasetWithDatasetId:did
              finalAUSequence:(uint32_t)[run count]];
        }
        did++;
    }
    for (NSString *name in gNames) {
        if (filterDid && did != filterDid.unsignedIntValue) {
            did++;
            continue;
        }
        TTIOGenomicRun *grun = dataset.genomicRuns[name];
        if (hasEodVisitor) {
            [visitor walker:self
visitEndOfDatasetWithDatasetId:did
              finalAUSequence:(uint32_t)grun.readCount];
        }
        did++;
    }

    // ── 5. EndOfStream ────────────────────────────────────────────
    if ([visitor respondsToSelector:@selector(walkerVisitEndOfStream:)]) {
        [visitor walkerVisitEndOfStream:self];
    }

    return YES;
}

@end
