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
