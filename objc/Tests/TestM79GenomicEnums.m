// TestM79GenomicEnums.m — v0.11 M79.
//
// Modality abstraction + genomic enumerations. Purely additive
// groundwork for the v0.11 genomic milestone series:
//
//   * MPGOPrecisionUInt8 round-trips through HDF5 + Memory providers.
//   * New MPGOCompression ordinals 4-8 (rANS / base-pack /
//     quality-binned / name-tokenized) have stable integer values.
//   * MPGOAcquisitionMode gains GenomicWGS = 7, GenomicWES = 8.
//   * Transport MPGOAccessUnit accepts spectrumClass = 5 (GenomicRead)
//     without crashing; MSImagePixel extension MUST NOT activate.
//   * MPGOAcquisitionRun.modality defaults to @"mass_spectrometry"
//     so v0.10 files surface as mass-spec runs.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/MPGOStorageProtocols.h"
#import "Providers/MPGOProviderRegistry.h"
#import "Providers/MPGOMemoryProvider.h"
#import "Transport/MPGOAccessUnit.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>

static NSString *m79GePath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_m79ge_%d_%@",
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

    id<MPGOStorageProvider> w =
        [[MPGOProviderRegistry sharedRegistry]
            openURL:url
               mode:MPGOStorageOpenModeCreate
           provider:providerName
              error:&err];
    PASS(w != nil, "M79: provider opens for create (%s)",
         [providerName UTF8String]);

    id<MPGOStorageGroup> root = [w rootGroupWithError:&err];
    id<MPGOStorageDataset> ds =
        [root createDatasetNamed:@"bases"
                        precision:MPGOPrecisionUInt8
                           length:N
                        chunkSize:0
                      compression:MPGOCompressionNone
                 compressionLevel:0
                            error:&err];
    PASS(ds != nil, "M79: UINT8 dataset created (%s)",
         [providerName UTF8String]);
    PASS([ds writeAll:expected error:&err],
         "M79: UINT8 dataset writes (%s)", [providerName UTF8String]);
    [w close];

    id<MPGOStorageProvider> r =
        [[MPGOProviderRegistry sharedRegistry]
            openURL:url
               mode:MPGOStorageOpenModeRead
           provider:providerName
              error:&err];
    PASS(r != nil, "M79: provider reopens read-only (%s)",
         [providerName UTF8String]);
    id<MPGOStorageGroup> root2 = [r rootGroupWithError:&err];
    id<MPGOStorageDataset> back =
        [root2 openDatasetNamed:@"bases" error:&err];
    PASS(back != nil, "M79: UINT8 dataset reopens (%s)",
         [providerName UTF8String]);
    PASS([back precision] == MPGOPrecisionUInt8,
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
        [MPGOMemoryProvider discardStore:url];
        uint8RoundTripThroughProvider(@"memory", url);
        [MPGOMemoryProvider discardStore:url];
    }

    // ── 3. MPGOPrecisionUInt8 element size == 1 ────────────────────
    {
        MPGOEncodingSpec *spec =
            [MPGOEncodingSpec specWithPrecision:MPGOPrecisionUInt8
                           compressionAlgorithm:MPGOCompressionNone
                                      byteOrder:MPGOByteOrderLittleEndian];
        PASS([spec elementSize] == 1,
             "M79: MPGOPrecisionUInt8 element size is 1 byte");
    }

    // ── 4. New compression ordinals are stable ─────────────────────
    {
        PASS((NSUInteger)MPGOCompressionNone           == 0, "Compression.None == 0");
        PASS((NSUInteger)MPGOCompressionZlib           == 1, "Compression.Zlib == 1");
        PASS((NSUInteger)MPGOCompressionLZ4            == 2, "Compression.LZ4 == 2");
        PASS((NSUInteger)MPGOCompressionNumpressDelta  == 3, "Compression.NumpressDelta == 3");
        PASS((NSUInteger)MPGOCompressionRansOrder0     == 4, "Compression.RansOrder0 == 4");
        PASS((NSUInteger)MPGOCompressionRansOrder1     == 5, "Compression.RansOrder1 == 5");
        PASS((NSUInteger)MPGOCompressionBasePack       == 6, "Compression.BasePack == 6");
        PASS((NSUInteger)MPGOCompressionQualityBinned  == 7, "Compression.QualityBinned == 7");
        PASS((NSUInteger)MPGOCompressionNameTokenized  == 8, "Compression.NameTokenized == 8");
    }

    // ── 5. AcquisitionMode genomic ordinals are stable ─────────────
    {
        PASS((NSUInteger)MPGOAcquisitionModeMS1DDA      == 0, "AcquisitionMode.MS1DDA == 0");
        PASS((NSUInteger)MPGOAcquisitionModeGenomicWGS  == 7, "AcquisitionMode.GenomicWGS == 7");
        PASS((NSUInteger)MPGOAcquisitionModeGenomicWES  == 8, "AcquisitionMode.GenomicWES == 8");
    }

    // ── 6. AccessUnit spectrumClass=5 (GenomicRead) round-trip ─────
    {
        MPGOAccessUnit *au =
            [[MPGOAccessUnit alloc]
                initWithSpectrumClass:5
                      acquisitionMode:(uint8_t)MPGOAcquisitionModeGenomicWGS
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
        MPGOAccessUnit *back =
            [MPGOAccessUnit decodeFromBytes:(const uint8_t *)blob.bytes
                                     length:blob.length
                                      error:&err];
        PASS(back != nil, "M79: GenomicRead AU decodes");
        PASS(back.spectrumClass == 5, "M79: spectrumClass preserved as 5");
        PASS(back.acquisitionMode ==
                 (uint8_t)MPGOAcquisitionModeGenomicWGS,
             "M79: acquisitionMode preserved as GenomicWGS");
        PASS(back.channels.count == 0, "M79: zero channels preserved");
        // MSImagePixel extension MUST NOT activate for spectrumClass=5.
        PASS(back.pixelX == 0, "M79: pixelX stays 0 for GenomicRead");
        PASS(back.pixelY == 0, "M79: pixelY stays 0 for GenomicRead");
        PASS(back.pixelZ == 0, "M79: pixelZ stays 0 for GenomicRead");
    }

    // ── 7. AcquisitionRun.modality default ─────────────────────────
    {
        MPGOInstrumentConfig *cfg =
            [[MPGOInstrumentConfig alloc]
                initWithManufacturer:@"Test"
                               model:@"M79"
                        serialNumber:@""
                          sourceType:@""
                        analyzerType:@""
                        detectorType:@""];
        MPGOAcquisitionRun *run =
            [[MPGOAcquisitionRun alloc]
                initWithSpectra:@[]
                acquisitionMode:MPGOAcquisitionModeMS1DDA
               instrumentConfig:cfg];
        PASS(run != nil, "M79: empty MS run constructible");
        PASS([run.modality isEqualToString:@"mass_spectrometry"],
             "M79: modality defaults to mass_spectrometry");
    }
}
