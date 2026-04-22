/*
 * TestMilestone19 — mzML writer round trip + indexedmzML byte offsets.
 *
 * Builds a small MPGOSpectralDataset, serializes it via
 * MPGOMzMLWriter, parses the result with MPGOMzMLReader, and
 * compares the in-memory spectra field by field. Also verifies that
 * the byte offsets stored in <indexList> point at the literal
 * '<spectrum ' tag in the output.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Core/MPGOSignalArray.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOIsolationWindow.h"
#import "Export/MPGOMzMLWriter.h"
#import "Import/MPGOMzMLReader.h"

#import <unistd.h>

static MPGOAcquisitionRun *m19BuildRun(NSUInteger nSpec, NSUInteger nPts)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < nSpec; k++) {
        double mz[16], in[16];
        for (NSUInteger i = 0; i < nPts; i++) {
            mz[i] = 100.0 + (double)(k * nPts + i) * 0.5;
            in[i] = (double)(k + 1) * 10.0 + (double)i;
        }
        MPGOEncodingSpec *enc =
            [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                           compressionAlgorithm:MPGOCompressionZlib
                                      byteOrder:MPGOByteOrderLittleEndian];
        MPGOSignalArray *mzA =
            [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz length:nPts * sizeof(double)]
                                              length:nPts
                                            encoding:enc
                                                axis:nil];
        MPGOSignalArray *inA =
            [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in length:nPts * sizeof(double)]
                                              length:nPts
                                            encoding:enc
                                                axis:nil];
        [spectra addObject:
            [[MPGOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:MPGOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k * 0.5
                                          precursorMz:0
                                      precursorCharge:0
                                                error:NULL]];
    }
    MPGOInstrumentConfig *cfg =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    return [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:MPGOAcquisitionModeMS1DDA
                                      instrumentConfig:cfg];
}

static MPGOSpectralDataset *m19BuildDataset(NSUInteger nSpec, NSUInteger nPts)
{
    return [[MPGOSpectralDataset alloc] initWithTitle:@"m19"
                                   isaInvestigationId:@""
                                               msRuns:@{@"run_0001": m19BuildRun(nSpec, nPts)}
                                              nmrRuns:@{}
                                      identifications:@[]
                                      quantifications:@[]
                                    provenanceRecords:@[]
                                          transitions:nil];
}

void testMilestone19(void)
{
    // ---- 1. Uncompressed round trip ----
    {
        MPGOSpectralDataset *ds = m19BuildDataset(3, 6);
        NSError *err = nil;
        NSData *xml = [MPGOMzMLWriter dataForDataset:ds
                                     zlibCompression:NO
                                               error:&err];
        PASS(xml != nil && xml.length > 0, "writer produces non-empty mzML");
        PASS(err == nil, "no error on write");

        // v0.9 M64: writer must emit required XSD sections + activation
        // + populated <instrumentConfiguration>. Assert the output shape
        // so regressions surface at the unit-test layer.
        NSString *xmlStr = [[NSString alloc] initWithData:xml
                                                 encoding:NSUTF8StringEncoding];
        PASS([xmlStr rangeOfString:@"<softwareList"].location != NSNotFound,
             "v0.9 M64: mzML output carries <softwareList>");
        PASS([xmlStr rangeOfString:@"<instrumentConfigurationList"].location != NSNotFound,
             "v0.9 M64: mzML output carries <instrumentConfigurationList>");
        PASS([xmlStr rangeOfString:@"<dataProcessingList"].location != NSNotFound,
             "v0.9 M64: mzML output carries <dataProcessingList>");
        PASS([xmlStr rangeOfString:@"MS:1000031"].location != NSNotFound,
             "v0.9 M64: <instrumentConfiguration> carries MS:1000031 cvParam");

        // Parse back with MPGOMzMLReader.
        err = nil;
        MPGOSpectralDataset *round =
            [MPGOMzMLReader readFromData:xml error:&err];
        PASS(round != nil, "MPGOMzMLReader re-parses writer output");
        PASS(err == nil, "no error on re-parse");

        MPGOAcquisitionRun *run = round.msRuns[round.msRuns.allKeys.firstObject];
        PASS(run != nil, "round-tripped run present");
        PASS(run.spectrumIndex.count == 3, "spectrum count preserved (3)");

        NSError *e2 = nil;
        MPGOMassSpectrum *s0 = [run spectrumAtIndex:0 error:&e2];
        PASS(s0.mzArray.length == 6, "spectrum 0 has 6 m/z points");
        const double *mz = s0.mzArray.buffer.bytes;
        const double *in = s0.intensityArray.buffer.bytes;
        PASS(mz[0] == 100.0, "spectrum 0 first m/z exact");
        PASS(mz[5] == 102.5, "spectrum 0 last m/z exact");
        PASS(in[0] == 10.0, "spectrum 0 first intensity exact");
    }

    // ---- 2. zlib-compressed round trip ----
    {
        MPGOSpectralDataset *ds = m19BuildDataset(4, 8);
        NSError *err = nil;
        NSData *xml = [MPGOMzMLWriter dataForDataset:ds
                                     zlibCompression:YES
                                               error:&err];
        PASS(xml != nil, "writer produces zlib-compressed mzML");

        MPGOSpectralDataset *round = [MPGOMzMLReader readFromData:xml error:&err];
        PASS(round != nil, "re-parses zlib-compressed output");
        MPGOAcquisitionRun *run = round.msRuns[round.msRuns.allKeys.firstObject];
        PASS(run.spectrumIndex.count == 4, "compressed round trip spectrum count");

        // Bit-exact value check on the last spectrum
        NSError *e2 = nil;
        MPGOMassSpectrum *s3 = [run spectrumAtIndex:3 error:&e2];
        const double *mz = s3.mzArray.buffer.bytes;
        const double *in = s3.intensityArray.buffer.bytes;
        PASS(mz[0] == 100.0 + (3.0 * 8.0 + 0.0) * 0.5,
             "spectrum 3 first m/z exact (compressed)");
        PASS(in[7] == (3.0 + 1.0) * 10.0 + 7.0,
             "spectrum 3 last intensity exact (compressed)");
    }

    // ---- 3. indexedmzML byte offsets are byte-correct ----
    {
        MPGOSpectralDataset *ds = m19BuildDataset(2, 4);
        NSError *err = nil;
        NSData *xml = [MPGOMzMLWriter dataForDataset:ds
                                     zlibCompression:NO
                                               error:&err];
        NSString *s = [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];

        // Find the <indexList> block and extract the first <offset>.
        NSRange idxRange = [s rangeOfString:@"<index name=\"spectrum\">"];
        PASS(idxRange.location != NSNotFound, "indexList spectrum index present");

        // Extract first offset value
        NSRange firstOffset = [s rangeOfString:@"<offset idRef=\"scan=1\">"
                                       options:0
                                         range:NSMakeRange(idxRange.location,
                                                           s.length - idxRange.location)];
        PASS(firstOffset.location != NSNotFound, "first offset row present");
        NSUInteger start = firstOffset.location + firstOffset.length;
        NSRange closeTag = [s rangeOfString:@"</offset>"
                                    options:0
                                      range:NSMakeRange(start, s.length - start)];
        NSString *offsetStr = [s substringWithRange:NSMakeRange(start, closeTag.location - start)];
        unsigned long long byteOffset = strtoull([offsetStr UTF8String], NULL, 10);
        PASS(byteOffset > 0, "first spectrum offset parsed");

        // The byte at that offset must be the '<' of the <spectrum tag.
        const uint8_t *bytes = xml.bytes;
        PASS(byteOffset < xml.length, "offset is inside the file");
        NSString *peek = [[NSString alloc]
            initWithBytes:bytes + byteOffset
                   length:MIN((NSUInteger)9, xml.length - byteOffset)
                 encoding:NSUTF8StringEncoding];
        PASS([peek isEqualToString:@"<spectrum"],
             "first offset points at the <spectrum tag");
    }
}

// M74 Slice D: writer emits real activation method + isolation window from
// the run's SpectrumIndex instead of a hardcoded CID placeholder, and
// round-trips via MPGOMzMLReader.
void testMilestone19M74(void)
{
    NSUInteger nPts = 4;
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];

    double mz1[] = {100.0, 101.0, 102.0, 103.0};
    double in1[] = {10.0, 20.0, 30.0, 40.0};
    MPGOSignalArray *mz1A =
        [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz1 length:sizeof(mz1)]
                                          length:nPts encoding:enc axis:nil];
    MPGOSignalArray *in1A =
        [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in1 length:sizeof(in1)]
                                          length:nPts encoding:enc axis:nil];
    NSError *err = nil;
    MPGOMassSpectrum *ms1 =
        [[MPGOMassSpectrum alloc] initWithMzArray:mz1A
                                   intensityArray:in1A
                                          msLevel:1
                                         polarity:MPGOPolarityPositive
                                       scanWindow:nil
                                 activationMethod:MPGOActivationMethodNone
                                  isolationWindow:nil
                                    indexPosition:0
                                  scanTimeSeconds:0.0
                                      precursorMz:0.0
                                  precursorCharge:0
                                            error:&err];
    PASS(ms1 != nil, "M74: MS1 spectrum built");

    double mz2[] = {200.0, 201.0, 202.0, 203.0};
    double in2[] = {11.0, 22.0, 33.0, 44.0};
    MPGOSignalArray *mz2A =
        [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:mz2 length:sizeof(mz2)]
                                          length:nPts encoding:enc axis:nil];
    MPGOSignalArray *in2A =
        [[MPGOSignalArray alloc] initWithBuffer:[NSData dataWithBytes:in2 length:sizeof(in2)]
                                          length:nPts encoding:enc axis:nil];
    MPGOIsolationWindow *iw =
        [MPGOIsolationWindow windowWithTargetMz:445.3
                                     lowerOffset:0.5
                                     upperOffset:0.5];
    MPGOMassSpectrum *ms2 =
        [[MPGOMassSpectrum alloc] initWithMzArray:mz2A
                                   intensityArray:in2A
                                          msLevel:2
                                         polarity:MPGOPolarityPositive
                                       scanWindow:nil
                                 activationMethod:MPGOActivationMethodHCD
                                  isolationWindow:iw
                                    indexPosition:1
                                  scanTimeSeconds:1.5
                                      precursorMz:445.3
                                  precursorCharge:2
                                            error:&err];
    PASS(ms2 != nil, "M74: MS2 spectrum built with HCD + isolation window");

    MPGOInstrumentConfig *cfg =
        [[MPGOInstrumentConfig alloc] initWithManufacturer:@""
                                                     model:@""
                                              serialNumber:@""
                                                sourceType:@""
                                              analyzerType:@""
                                              detectorType:@""];
    MPGOAcquisitionRun *run =
        [[MPGOAcquisitionRun alloc] initWithSpectra:@[ms1, ms2]
                                    acquisitionMode:MPGOAcquisitionModeMS1DDA
                                   instrumentConfig:cfg];
    PASS(run.spectrumIndex.hasActivationDetail,
         "M74: index carries activation-detail columns");
    PASS([run.spectrumIndex activationMethodAt:1] == MPGOActivationMethodHCD,
         "M74: index records HCD at position 1");

    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"m74-writer"
                                isaInvestigationId:@""
                                            msRuns:@{@"run_0001": run}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];

    NSData *xml = [MPGOMzMLWriter dataForDataset:ds
                                 zlibCompression:NO
                                           error:&err];
    PASS(xml != nil && xml.length > 0, "M74: writer produces output");

    NSString *s = [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];

    // HCD accession present, CID placeholder gone.
    PASS([s rangeOfString:@"MS:1000422"].location != NSNotFound,
         "M74 writer emits MS:1000422 (HCD)");
    PASS([s rangeOfString:@"MS:1000133"].location == NSNotFound,
         "M74 writer no longer emits MS:1000133 (CID placeholder)");

    // Isolation-window cvParams present.
    PASS([s rangeOfString:@"MS:1000827"].location != NSNotFound,
         "M74 writer emits MS:1000827 (isolation target m/z)");
    PASS([s rangeOfString:@"MS:1000828"].location != NSNotFound,
         "M74 writer emits MS:1000828 (isolation lower offset)");
    PASS([s rangeOfString:@"MS:1000829"].location != NSNotFound,
         "M74 writer emits MS:1000829 (isolation upper offset)");

    // XSD ordering: <isolationWindow> must appear before <selectedIonList>
    // inside the MS2 precursor block.
    NSRange iwRange = [s rangeOfString:@"<isolationWindow>"];
    NSRange silRange = [s rangeOfString:@"<selectedIonList"];
    PASS(iwRange.location != NSNotFound && silRange.location != NSNotFound,
         "M74 writer emits both isolationWindow and selectedIonList");
    PASS(iwRange.location < silRange.location,
         "M74 writer emits isolationWindow before selectedIonList");

    // Re-parse through the reader and confirm the round-trip.
    MPGOSpectralDataset *round = [MPGOMzMLReader readFromData:xml error:&err];
    PASS(round != nil, "M74: writer output re-parses");
    MPGOAcquisitionRun *backRun = [round.msRuns.allValues firstObject];
    MPGOSpectrumIndex *backIdx = backRun.spectrumIndex;
    PASS(backIdx.hasActivationDetail,
         "M74: round-tripped index carries activation-detail columns");
    PASS([backIdx activationMethodAt:1] == MPGOActivationMethodHCD,
         "M74: round-tripped MS2 activation method is HCD");
    MPGOIsolationWindow *backIw = [backIdx isolationWindowAt:1];
    PASS(backIw != nil, "M74: round-tripped isolation window present");
    PASS(backIw && fabs(backIw.targetMz - 445.3) < 1e-9,
         "M74: round-tripped isolation target = 445.3");
    PASS(backIw && fabs(backIw.lowerOffset - 0.5) < 1e-9,
         "M74: round-tripped isolation lower offset = 0.5");
    PASS(backIw && fabs(backIw.upperOffset - 0.5) < 1e-9,
         "M74: round-tripped isolation upper offset = 0.5");

    // MS1 row must not have emitted activation or isolation metadata.
    PASS([backIdx activationMethodAt:0] == MPGOActivationMethodNone,
         "M74: round-tripped MS1 activation method is None");
    PASS([backIdx isolationWindowAt:0] == nil,
         "M74: round-tripped MS1 has no isolation window");
}
