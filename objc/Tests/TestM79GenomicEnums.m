// TestM79GenomicEnums.m — v0.11 M79.
//
// Modality abstraction + genomic enumerations. Purely additive
// groundwork for the v0.11 genomic milestone series:
//
//   * TTIOPrecisionUInt8 round-trips through HDF5 + Memory providers.
//   * New TTIOCompression ordinals 4-8 (rANS / base-pack /
//     quality-binned / name-tokenized) have stable integer values.
//   * TTIOAcquisitionMode gains GenomicWGS = 7, GenomicWES = 8.
//   * Transport TTIOAccessUnit accepts spectrumClass = 5 (GenomicRead)
//     without crashing; MSImagePixel extension MUST NOT activate.
//   * TTIOAcquisitionRun.modality defaults to @"mass_spectrometry"
//     so v0.10 files surface as mass-spec runs.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOMemoryProvider.h"
#import "Transport/TTIOAccessUnit.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import <unistd.h>

static NSString *m79GePath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m79ge_%d_%@",
            (int)getpid(), suffix];
}

static NSData *uint8Sample(NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        p[i] = (uint8_t)(i & 0xFF);
    }
    return d;
}

static void uint8RoundTripThroughProvider(NSString *providerName,
                                           NSString *url)
{
    const NSUInteger N = 1000;
    NSData *expected = uint8Sample(N);
    NSError *err = nil;

    id<TTIOStorageProvider> w =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:url
               mode:TTIOStorageOpenModeCreate
           provider:providerName
              error:&err];
    PASS(w != nil, "M79: provider opens for create (%s)",
         [providerName UTF8String]);

    id<TTIOStorageGroup> root = [w rootGroupWithError:&err];
    id<TTIOStorageDataset> ds =
        [root createDatasetNamed:@"bases"
                        precision:TTIOPrecisionUInt8
                           length:N
                        chunkSize:0
                      compression:TTIOCompressionNone
                 compressionLevel:0
                            error:&err];
    PASS(ds != nil, "M79: UINT8 dataset created (%s)",
         [providerName UTF8String]);
    PASS([ds writeAll:expected error:&err],
         "M79: UINT8 dataset writes (%s)", [providerName UTF8String]);
    [w close];

    id<TTIOStorageProvider> r =
        [[TTIOProviderRegistry sharedRegistry]
            openURL:url
               mode:TTIOStorageOpenModeRead
           provider:providerName
              error:&err];
    PASS(r != nil, "M79: provider reopens read-only (%s)",
         [providerName UTF8String]);
    id<TTIOStorageGroup> root2 = [r rootGroupWithError:&err];
    id<TTIOStorageDataset> back =
        [root2 openDatasetNamed:@"bases" error:&err];
    PASS(back != nil, "M79: UINT8 dataset reopens (%s)",
         [providerName UTF8String]);
    PASS([back precision] == TTIOPrecisionUInt8,
         "M79: precision survives round-trip (%s)",
         [providerName UTF8String]);

    NSData *got = [back readAll:&err];
    PASS(got != nil, "M79: UINT8 readAll returned data (%s)",
         [providerName UTF8String]);
    PASS([got isEqualToData:expected],
         "M79: UINT8 bytes round-trip byte-exactly (%s)",
         [providerName UTF8String]);
    [r close];
}

void testM79GenomicEnums(void)
{
    // ── 1. UINT8 round-trip via HDF5 provider ──────────────────────
    {
        NSString *path = m79GePath(@"uint8.h5");
        unlink([path fileSystemRepresentation]);
        uint8RoundTripThroughProvider(@"hdf5", path);
        unlink([path fileSystemRepresentation]);
    }

    // ── 2. UINT8 round-trip via Memory provider ────────────────────
    {
        NSString *url = [NSString stringWithFormat:@"memory://m79ge-%d",
                         (int)getpid()];
        [TTIOMemoryProvider discardStore:url];
        uint8RoundTripThroughProvider(@"memory", url);
        [TTIOMemoryProvider discardStore:url];
    }

    // ── 3. TTIOPrecisionUInt8 element size == 1 ────────────────────
    {
        TTIOEncodingSpec *spec =
            [TTIOEncodingSpec specWithPrecision:TTIOPrecisionUInt8
                           compressionAlgorithm:TTIOCompressionNone
                                      byteOrder:TTIOByteOrderLittleEndian];
        PASS([spec elementSize] == 1,
             "M79: TTIOPrecisionUInt8 element size is 1 byte");
    }

    // ── 4. New compression ordinals are stable ─────────────────────
    {
        PASS((NSUInteger)TTIOCompressionNone             == 0, "Compression.None == 0");
        PASS((NSUInteger)TTIOCompressionZlib             == 1, "Compression.Zlib == 1");
        PASS((NSUInteger)TTIOCompressionLZ4              == 2, "Compression.LZ4 == 2");
        PASS((NSUInteger)TTIOCompressionNumpressDelta    == 3, "Compression.NumpressDelta == 3");
        PASS((NSUInteger)TTIOCompressionRansOrder0       == 4, "Compression.RansOrder0 == 4");
        PASS((NSUInteger)TTIOCompressionRansOrder1       == 5, "Compression.RansOrder1 == 5");
        PASS((NSUInteger)TTIOCompressionBasePack         == 6, "Compression.BasePack == 6");
        PASS((NSUInteger)TTIOCompressionQualityBinned    == 7, "Compression.QualityBinned == 7");
        // Slots 8/9/10 reserved (v1 codecs removed in v1.0 reset).
        PASS((NSUInteger)TTIOCompressionDeltaRansOrder0  == 11, "Compression.DeltaRansOrder0 == 11");
        PASS((NSUInteger)TTIOCompressionFqzcompNx16Z     == 12, "Compression.FqzcompNx16Z == 12");
        PASS((NSUInteger)TTIOCompressionMateInlineV2     == 13, "Compression.MateInlineV2 == 13");
        PASS((NSUInteger)TTIOCompressionRefDiffV2        == 14, "Compression.RefDiffV2 == 14");
        PASS((NSUInteger)TTIOCompressionNameTokenizedV2  == 15, "Compression.NameTokenizedV2 == 15");
    }

    // ── 5. AcquisitionMode genomic ordinals are stable ─────────────
    {
        PASS((NSUInteger)TTIOAcquisitionModeMS1DDA      == 0, "AcquisitionMode.MS1DDA == 0");
        PASS((NSUInteger)TTIOAcquisitionModeGenomicWGS  == 7, "AcquisitionMode.GenomicWGS == 7");
        PASS((NSUInteger)TTIOAcquisitionModeGenomicWES  == 8, "AcquisitionMode.GenomicWES == 8");
    }

    // ── 6. AccessUnit spectrumClass=5 (GenomicRead) round-trip ─────
    {
        TTIOAccessUnit *au =
            [[TTIOAccessUnit alloc]
                initWithSpectrumClass:5
                      acquisitionMode:(uint8_t)TTIOAcquisitionModeGenomicWGS
                              msLevel:0
                             polarity:2     // unknown — wire convention
                        retentionTime:0.0
                          precursorMz:0.0
                      precursorCharge:0
                          ionMobility:0.0
                    basePeakIntensity:0.0
                             channels:@[]
                               pixelX:0
                               pixelY:0
                               pixelZ:0];
        PASS(au != nil, "M79: GenomicRead AU constructible");

        NSData *blob = [au encode];
        PASS(blob != nil && blob.length >= 38,
             "M79: GenomicRead AU encodes (>= 38 byte fixed prefix)");

        NSError *err = nil;
        TTIOAccessUnit *back =
            [TTIOAccessUnit decodeFromBytes:(const uint8_t *)blob.bytes
                                     length:blob.length
                                      error:&err];
        PASS(back != nil, "M79: GenomicRead AU decodes");
        PASS(back.spectrumClass == 5, "M79: spectrumClass preserved as 5");
        PASS(back.acquisitionMode ==
                 (uint8_t)TTIOAcquisitionModeGenomicWGS,
             "M79: acquisitionMode preserved as GenomicWGS");
        PASS(back.channels.count == 0, "M79: zero channels preserved");
        // MSImagePixel extension MUST NOT activate for spectrumClass=5.
        PASS(back.pixelX == 0, "M79: pixelX stays 0 for GenomicRead");
        PASS(back.pixelY == 0, "M79: pixelY stays 0 for GenomicRead");
        PASS(back.pixelZ == 0, "M79: pixelZ stays 0 for GenomicRead");
    }

    // ── 7. AcquisitionRun.modality default ─────────────────────────
    {
        TTIOInstrumentConfig *cfg =
            [[TTIOInstrumentConfig alloc]
                initWithManufacturer:@"Test"
                               model:@"M79"
                        serialNumber:@""
                          sourceType:@""
                        analyzerType:@""
                        detectorType:@""];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc]
                initWithSpectra:@[]
                acquisitionMode:TTIOAcquisitionModeMS1DDA
               instrumentConfig:cfg];
        PASS(run != nil, "M79: empty MS run constructible");
        PASS([run.modality isEqualToString:@"mass_spectrometry"],
             "M79: modality defaults to mass_spectrometry");
    }
}
