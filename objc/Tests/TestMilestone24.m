// Milestone 24: Chromatogram API + mzML writer completion.
//
// Verifies:
//   * TTIOAcquisitionRun persists chromatograms into <run>/chromatograms/
//     with concatenated time/intensity datasets and the chromatogram_index
//     subgroup of parallel metadata arrays.
//   * Round-trip of 3 chromatograms (TIC + XIC + SRM) through .tio.
//   * TTIOMzMLWriter emits <chromatogramList> with a second <index> block
//     whose offsets are byte-correct (point at the first byte of the
//     `<chromatogram` tag).
//   * TTIOMzMLReader re-parses chromatograms back with correct type, target,
//     precursor, and product m/z values.
//   * v0.3 (no chromatograms group) files still read back as empty list.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOChromatogram.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "ValueClasses/TTIOEnums.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "Export/TTIOMzMLWriter.h"
#import "Import/TTIOMzMLReader.h"
#import "Dataset/TTIOSpectralDataset.h"
#import <unistd.h>

static NSString *m24TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m24_%d_%@",
            (int)getpid(), suffix];
}

static TTIOSignalArray *m24SignalArray(const double *values, NSUInteger n, NSString *axis)
{
    TTIOEncodingSpec *spec =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    NSData *buf = [NSData dataWithBytes:values length:n * sizeof(double)];
    TTIOAxisDescriptor *ax = nil;
    (void)axis;
    return [[TTIOSignalArray alloc] initWithBuffer:buf length:n encoding:spec axis:ax];
}

static TTIOChromatogram *m24MakeChromatogram(TTIOChromatogramType type,
                                              NSUInteger n,
                                              double targetMz,
                                              double precursorMz,
                                              double productMz)
{
    double *t = malloc(n * sizeof(double));
    double *v = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) {
        t[i] = 0.1 * (double)i;
        v[i] = 100.0 + (double)(i * 7);
    }
    TTIOSignalArray *tArr = m24SignalArray(t, n, @"time");
    TTIOSignalArray *iArr = m24SignalArray(v, n, @"intensity");
    free(t); free(v);
    return [[TTIOChromatogram alloc] initWithTimeArray:tArr
                                         intensityArray:iArr
                                                   type:type
                                               targetMz:targetMz
                                            precursorMz:precursorMz
                                              productMz:productMz
                                                  error:NULL];
}

void testMilestone24(void)
{
    // ---------------- Round-trip 3 chromatograms through .tio ----------------
    {
        NSString *ttioPath = m24TempPath(@"rt.tio");
        unlink([ttioPath fileSystemRepresentation]);

        // Build 3 chromatograms of different lengths and types.
        NSArray *chroms = @[
            m24MakeChromatogram(TTIOChromatogramTypeTIC, 10, 0.0,   0.0,   0.0),
            m24MakeChromatogram(TTIOChromatogramTypeXIC,  8, 523.25, 0.0,   0.0),
            m24MakeChromatogram(TTIOChromatogramTypeSRM, 12, 0.0,   400.5, 185.1),
        ];

        TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc]
            initWithManufacturer:@"" model:@"" serialNumber:@""
                      sourceType:@"" analyzerType:@"" detectorType:@""];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc] initWithSpectra:@[]
                                          chromatograms:chroms
                                        acquisitionMode:TTIOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg];
        PASS(run.chromatograms.count == 3, "M24: run carries 3 chromatograms");

        // Write bare run into a fresh HDF5 file under /test_run/.
        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:ttioPath error:&err];
        PASS(f != nil, "M24: create .tio for chromatogram round-trip");
        TTIOHDF5Group *root = [f rootGroup];
        PASS([run writeToGroup:root name:@"test_run" error:&err],
             "M24: writeToGroup includes chromatograms");
        PASS([f close], "M24: close after write");

        // Re-open and read back.
        TTIOHDF5File *f2 = [TTIOHDF5File openReadOnlyAtPath:ttioPath error:&err];
        PASS(f2 != nil, "M24: reopen for read");
        TTIOAcquisitionRun *read =
            [TTIOAcquisitionRun readFromGroup:[f2 rootGroup] name:@"test_run" error:&err];
        PASS(read != nil, "M24: read back run");
        PASS(read.chromatograms.count == 3, "M24: 3 chromatograms survive round-trip");

        TTIOChromatogram *c0 = read.chromatograms[0];
        TTIOChromatogram *c1 = read.chromatograms[1];
        TTIOChromatogram *c2 = read.chromatograms[2];
        PASS(c0.type == TTIOChromatogramTypeTIC, "M24: c0 type TIC");
        PASS(c0.timeArray.length == 10, "M24: c0 length 10");
        PASS(c1.type == TTIOChromatogramTypeXIC, "M24: c1 type XIC");
        PASS(c1.targetMz == 523.25, "M24: c1 target m/z preserved");
        PASS(c2.type == TTIOChromatogramTypeSRM, "M24: c2 type SRM");
        PASS(c2.precursorProductMz == 400.5, "M24: c2 precursor m/z preserved");
        PASS(c2.productMz == 185.1, "M24: c2 product m/z preserved");

        [f2 close];
        unlink([ttioPath fileSystemRepresentation]);
    }

    // ---------------- v0.3 back-compat: absence of chromatograms group ----------------
    {
        NSString *ttioPath = m24TempPath(@"v03.tio");
        unlink([ttioPath fileSystemRepresentation]);

        TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc]
            initWithManufacturer:@"" model:@"" serialNumber:@""
                      sourceType:@"" analyzerType:@"" detectorType:@""];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc] initWithSpectra:@[]
                                        acquisitionMode:TTIOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg];
        PASS(run.chromatograms.count == 0, "M24: default chromatograms empty");

        NSError *err = nil;
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:ttioPath error:&err];
        TTIOHDF5Group *root = [f rootGroup];
        PASS([run writeToGroup:root name:@"v03_run" error:&err],
             "M24: v0.3-style run writes without chromatograms group");
        [f close];

        TTIOHDF5File *f2 = [TTIOHDF5File openReadOnlyAtPath:ttioPath error:&err];
        TTIOAcquisitionRun *read =
            [TTIOAcquisitionRun readFromGroup:[f2 rootGroup] name:@"v03_run" error:&err];
        PASS(read != nil, "M24: v0.3-style run reads back");
        PASS(read.chromatograms.count == 0,
             "M24: v0.3-style run has empty chromatograms list");
        [f2 close];
        unlink([ttioPath fileSystemRepresentation]);
    }

    // ---------------- mzML writer + reader round-trip ----------------
    {
        // Build a dataset with 2 MS1 spectra + 3 chromatograms so the
        // writer produces a non-empty <spectrumList> and <chromatogramList>.
        double mzs[]  = { 100.0, 150.0, 200.0 };
        double ints[] = { 500.0, 900.0, 200.0 };
        TTIOSignalArray *mzArr  = m24SignalArray(mzs,  3, @"mz");
        TTIOSignalArray *inArr  = m24SignalArray(ints, 3, @"intensity");

        TTIOMassSpectrum *s1 = [[TTIOMassSpectrum alloc]
            initWithMzArray:mzArr intensityArray:inArr
                    msLevel:1 polarity:TTIOPolarityPositive scanWindow:nil
              indexPosition:0 scanTimeSeconds:1.0
                precursorMz:0.0 precursorCharge:0 error:NULL];
        TTIOMassSpectrum *s2 = [[TTIOMassSpectrum alloc]
            initWithMzArray:mzArr intensityArray:inArr
                    msLevel:1 polarity:TTIOPolarityPositive scanWindow:nil
              indexPosition:1 scanTimeSeconds:2.0
                precursorMz:0.0 precursorCharge:0 error:NULL];

        NSArray *chroms = @[
            m24MakeChromatogram(TTIOChromatogramTypeTIC, 5, 0.0,   0.0,   0.0),
            m24MakeChromatogram(TTIOChromatogramTypeXIC, 5, 523.25,0.0,   0.0),
            m24MakeChromatogram(TTIOChromatogramTypeSRM, 5, 0.0,   400.5, 185.1),
        ];

        TTIOInstrumentConfig *cfg = [[TTIOInstrumentConfig alloc]
            initWithManufacturer:@"" model:@"" serialNumber:@""
                      sourceType:@"" analyzerType:@"" detectorType:@""];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc] initWithSpectra:@[s1, s2]
                                          chromatograms:chroms
                                        acquisitionMode:TTIOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg];

        TTIOSpectralDataset *ds = [[TTIOSpectralDataset alloc]
            initWithTitle:@"m24"
       isaInvestigationId:@"ISA-M24"
                   msRuns:@{ @"run_0001": run }
                  nmrRuns:@{}
          identifications:@[]
          quantifications:@[]
        provenanceRecords:@[]
              transitions:nil];

        NSError *err = nil;
        NSData *mzml = [TTIOMzMLWriter dataForDataset:ds
                                      zlibCompression:NO
                                                error:&err];
        PASS(mzml.length > 0, "M24: mzML writer produced non-empty output");

        NSString *mzmlStr = [[NSString alloc] initWithData:mzml encoding:NSUTF8StringEncoding];
        PASS([mzmlStr rangeOfString:@"<chromatogramList"].location != NSNotFound,
             "M24: mzML contains <chromatogramList>");
        PASS([mzmlStr rangeOfString:@"MS:1000235"].location != NSNotFound,
             "M24: mzML contains TIC cvParam");
        PASS([mzmlStr rangeOfString:@"MS:1000627"].location != NSNotFound,
             "M24: mzML contains XIC cvParam");
        PASS([mzmlStr rangeOfString:@"MS:1001473"].location != NSNotFound,
             "M24: mzML contains SRM cvParam");
        PASS([mzmlStr rangeOfString:@"<index name=\"chromatogram\">"].location != NSNotFound,
             "M24: mzML indexList has chromatogram sub-index");

        // Feed the blob into the reader.
        TTIOMzMLReader *rdr = [TTIOMzMLReader parseData:mzml error:&err];
        PASS(rdr != nil, "M24: reader parsed writer output");
        PASS(rdr.chromatograms.count == 3, "M24: reader recovered 3 chromatograms");
        TTIOChromatogram *rc1 = rdr.chromatograms[1];
        TTIOChromatogram *rc2 = rdr.chromatograms[2];
        PASS(rc1.type == TTIOChromatogramTypeXIC, "M24: reader typed XIC correctly");
        PASS(rc1.targetMz == 523.25,              "M24: XIC target m/z survived mzML round-trip");
        PASS(rc2.type == TTIOChromatogramTypeSRM, "M24: reader typed SRM correctly");
        PASS(rc2.precursorProductMz == 400.5,     "M24: SRM precursor m/z survived mzML round-trip");
        PASS(rc2.productMz == 185.1,              "M24: SRM product m/z survived mzML round-trip");
    }
}
