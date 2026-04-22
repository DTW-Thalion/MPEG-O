#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Import/MPGOMzMLReader.h"
#import "Import/MPGOBase64.h"
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGOChromatogram.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "ValueClasses/MPGOEnums.h"
#import "ValueClasses/MPGOIsolationWindow.h"
#import <math.h>
#import <unistd.h>
#import <zlib.h>

static NSString *mpath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_mzml_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static NSString *base64OfDoubles(const double *vals, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:vals length:n * sizeof(double)];
    return [buf base64EncodedStringWithOptions:0];
}

static NSString *zlibBase64OfDoubles(const double *vals, NSUInteger n)
{
    NSUInteger rawLen = n * sizeof(double);
    uLongf destLen = compressBound((uLong)rawLen);
    Bytef *dest = malloc(destLen);
    int rc = compress(dest, &destLen, (const Bytef *)vals, (uLong)rawLen);
    if (rc != Z_OK) { free(dest); return nil; }
    NSData *d = [NSData dataWithBytes:dest length:destLen];
    free(dest);
    return [d base64EncodedStringWithOptions:0];
}

static NSString *buildSyntheticMzML(const double *mz1, const double *in1, NSUInteger n1,
                                     const double *mz2, const double *in2, NSUInteger n2,
                                     const double *tt,  const double *ti,  NSUInteger nc,
                                     BOOL compressSecondSpectrum)
{
    NSString *mz1b  = base64OfDoubles(mz1, n1);
    NSString *in1b  = base64OfDoubles(in1, n1);
    NSString *mz2b  = compressSecondSpectrum ? zlibBase64OfDoubles(mz2, n2) : base64OfDoubles(mz2, n2);
    NSString *in2b  = compressSecondSpectrum ? zlibBase64OfDoubles(in2, n2) : base64OfDoubles(in2, n2);
    NSString *ttb   = base64OfDoubles(tt, nc);
    NSString *tib   = base64OfDoubles(ti, nc);
    NSString *comp2 = compressSecondSpectrum
        ? @"<cvParam cvRef=\"MS\" accession=\"MS:1000574\" name=\"zlib compression\"/>"
        : @"<cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>";

    return [NSString stringWithFormat:
@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
@"<mzML xmlns=\"http://psi.hupo.org/ms/mzml\" version=\"1.1.0\">\n"
@"  <cvList count=\"1\"><cv id=\"MS\" fullName=\"PSI-MS\" URI=\"\"/></cvList>\n"
@"  <run id=\"synthetic_run\">\n"
@"    <spectrumList count=\"2\">\n"
@"      <spectrum index=\"0\" id=\"scan=1\" defaultArrayLength=\"%lu\">\n"
@"        <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"1\"/>\n"
@"        <cvParam cvRef=\"MS\" accession=\"MS:1000130\" name=\"positive scan\"/>\n"
@"        <scanList count=\"1\"><scan>\n"
@"          <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"12.5\" unitAccession=\"UO:0000010\"/>\n"
@"          <scanWindowList count=\"1\"><scanWindow>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000501\" name=\"scan window lower limit\" value=\"100\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000500\" name=\"scan window upper limit\" value=\"1000\"/>\n"
@"          </scanWindow></scanWindowList>\n"
@"        </scan></scanList>\n"
@"        <binaryDataArrayList count=\"2\">\n"
@"          <binaryDataArray>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"/>\n"
@"            <binary>%@</binary>\n"
@"          </binaryDataArray>\n"
@"          <binaryDataArray>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>\n"
@"            <binary>%@</binary>\n"
@"          </binaryDataArray>\n"
@"        </binaryDataArrayList>\n"
@"      </spectrum>\n"
@"      <spectrum index=\"1\" id=\"scan=2\" defaultArrayLength=\"%lu\">\n"
@"        <cvParam cvRef=\"MS\" accession=\"MS:1000511\" name=\"ms level\" value=\"2\"/>\n"
@"        <cvParam cvRef=\"MS\" accession=\"MS:1000129\" name=\"negative scan\"/>\n"
@"        <scanList count=\"1\"><scan>\n"
@"          <cvParam cvRef=\"MS\" accession=\"MS:1000016\" name=\"scan start time\" value=\"0.5\" unitAccession=\"UO:0000031\"/>\n"
@"        </scan></scanList>\n"
@"        <precursorList count=\"1\"><precursor>\n"
@"          <selectedIonList count=\"1\"><selectedIon>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000744\" name=\"selected ion m/z\" value=\"456.789\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000041\" name=\"charge state\" value=\"2\"/>\n"
@"          </selectedIon></selectedIonList>\n"
@"        </precursor></precursorList>\n"
@"        <binaryDataArrayList count=\"2\">\n"
@"          <binaryDataArray>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
@"            %@\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"/>\n"
@"            <binary>%@</binary>\n"
@"          </binaryDataArray>\n"
@"          <binaryDataArray>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
@"            %@\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>\n"
@"            <binary>%@</binary>\n"
@"          </binaryDataArray>\n"
@"        </binaryDataArrayList>\n"
@"      </spectrum>\n"
@"    </spectrumList>\n"
@"    <chromatogramList count=\"1\">\n"
@"      <chromatogram index=\"0\" id=\"TIC\" defaultArrayLength=\"%lu\">\n"
@"        <cvParam cvRef=\"MS\" accession=\"MS:1000235\" name=\"total ion current chromatogram\"/>\n"
@"        <binaryDataArrayList count=\"2\">\n"
@"          <binaryDataArray>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000595\" name=\"time array\"/>\n"
@"            <binary>%@</binary>\n"
@"          </binaryDataArray>\n"
@"          <binaryDataArray>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000576\" name=\"no compression\"/>\n"
@"            <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>\n"
@"            <binary>%@</binary>\n"
@"          </binaryDataArray>\n"
@"        </binaryDataArrayList>\n"
@"      </chromatogram>\n"
@"    </chromatogramList>\n"
@"  </run>\n"
@"</mzML>\n",
        (unsigned long)n1, mz1b, in1b,
        (unsigned long)n2, comp2, mz2b, comp2, in2b,
        (unsigned long)nc, ttb, tib];
}

static BOOL arrayMatchesDoubles(MPGOSignalArray *arr, const double *expected, NSUInteger n)
{
    if (!arr || arr.length != n) return NO;
    const double *got = (const double *)arr.buffer.bytes;
    for (NSUInteger i = 0; i < n; i++) {
        if (fabs(got[i] - expected[i]) > 1e-9) return NO;
    }
    return YES;
}

void testMzMLReader(void)
{
    // --- fixture values ---
    double mz1[] = { 100.0, 200.5, 300.25 };
    double in1[] = { 1000.0, 2500.0, 7500.0 };
    double mz2[] = { 150.1, 450.9 };
    double in2[] = { 111.0, 222.0 };
    double tt[]  = { 0.0, 1.0, 2.0, 3.0, 4.0 };
    double ti[]  = { 10.0, 20.0, 30.0, 40.0, 50.0 };

    // ---- uncompressed parse ----
    {
        NSString *xml = buildSyntheticMzML(mz1, in1, 3, mz2, in2, 2, tt, ti, 5, NO);
        NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];

        NSError *err = nil;
        MPGOMzMLReader *r = [MPGOMzMLReader parseData:data error:&err];
        PASS(r != nil, "parseData returns reader");
        PASS(err == nil, "no error on valid mzML");
        PASS(r.dataset != nil, "dataset materialized");

        MPGOAcquisitionRun *run = r.dataset.msRuns[@"synthetic_run"];
        PASS(run != nil, "run keyed by id");

        MPGOMassSpectrum *s0 = [run spectrumAtIndex:0 error:&err];
        MPGOMassSpectrum *s1 = [run spectrumAtIndex:1 error:&err];
        PASS(s0 != nil && s1 != nil, "both spectra retrievable");

        PASS(s0.msLevel == 1, "s0 ms level = 1");
        PASS(s1.msLevel == 2, "s1 ms level = 2");
        PASS(s0.polarity == MPGOPolarityPositive, "s0 positive polarity");
        PASS(s1.polarity == MPGOPolarityNegative, "s1 negative polarity");
        PASS(fabs(s0.scanTimeSeconds - 12.5) < 1e-9, "s0 scan time (seconds)");
        PASS(fabs(s1.scanTimeSeconds - 30.0) < 1e-9, "s1 scan time (minutes -> 30s)");
        PASS(fabs(s1.precursorMz - 456.789) < 1e-9, "s1 precursor m/z");
        PASS(s1.precursorCharge == 2, "s1 precursor charge");
        PASS(s0.scanWindow != nil && s0.scanWindow.minimum == 100.0 &&
             s0.scanWindow.maximum == 1000.0, "s0 scan window parsed");

        PASS(arrayMatchesDoubles(s0.mzArray, mz1, 3), "s0 mz array matches");
        PASS(arrayMatchesDoubles(s0.intensityArray, in1, 3), "s0 intensity matches");
        PASS(arrayMatchesDoubles(s1.mzArray, mz2, 2), "s1 mz array matches");
        PASS(arrayMatchesDoubles(s1.intensityArray, in2, 2), "s1 intensity matches");

        PASS(r.chromatograms.count == 1, "one chromatogram parsed");
        MPGOChromatogram *chrom = r.chromatograms[0];
        PASS(chrom.type == MPGOChromatogramTypeTIC, "chromatogram is TIC");
        PASS(arrayMatchesDoubles(chrom.timeArray, tt, 5), "chromatogram time array");
        PASS(arrayMatchesDoubles(chrom.intensityArray, ti, 5), "chromatogram intensity array");
    }

    // ---- zlib-compressed second spectrum ----
    {
        NSString *xml = buildSyntheticMzML(mz1, in1, 3, mz2, in2, 2, tt, ti, 5, YES);
        NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];

        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOMzMLReader readFromData:data error:&err];
        PASS(ds != nil, "zlib-compressed arrays parse");
        MPGOAcquisitionRun *run = ds.msRuns[@"synthetic_run"];
        MPGOMassSpectrum *s1 = [run spectrumAtIndex:1 error:&err];
        PASS(arrayMatchesDoubles(s1.mzArray, mz2, 2), "zlib s1 mz recovered");
        PASS(arrayMatchesDoubles(s1.intensityArray, in2, 2), "zlib s1 intensity recovered");
    }

    // ---- round-trip: mzML -> .mpgo -> read back ----
    {
        NSString *xml = buildSyntheticMzML(mz1, in1, 3, mz2, in2, 2, tt, ti, 5, NO);
        NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOMzMLReader readFromData:data error:&err];
        PASS(ds != nil, "parse for round-trip");

        NSString *path = mpath(@"roundtrip");
        unlink([path fileSystemRepresentation]);
        PASS([ds writeToFilePath:path error:&err], ".mpgo write succeeds");

        MPGOSpectralDataset *back =
            [MPGOSpectralDataset readFromFilePath:path error:&err];
        PASS(back != nil, ".mpgo read back");
        MPGOAcquisitionRun *run = back.msRuns[@"synthetic_run"];
        PASS(run != nil, "run survives round-trip");

        MPGOMassSpectrum *s0 = [run spectrumAtIndex:0 error:&err];
        MPGOMassSpectrum *s1 = [run spectrumAtIndex:1 error:&err];
        PASS(s0 != nil && s1 != nil, "both spectra recoverable post-round-trip");
        PASS(arrayMatchesDoubles(s0.mzArray, mz1, 3), "s0 mz survives round-trip");
        PASS(arrayMatchesDoubles(s1.mzArray, mz2, 2), "s1 mz survives round-trip");
        PASS(s1.msLevel == 2, "msLevel survives round-trip");
        unlink([path fileSystemRepresentation]);
    }

    // ---- malformed XML ----
    {
        NSString *bad = @"<?xml version=\"1.0\"?><mzML><run><spectrum";
        NSData *data = [bad dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOMzMLReader readFromData:data error:&err];
        PASS(ds == nil, "malformed XML returns nil");
        PASS(err != nil, "malformed XML populates NSError");
    }

    // ---- larger (100-peak) spectrum for perf sanity ----
    {
        const NSUInteger N = 100;
        double *mzL = malloc(N * sizeof(double));
        double *inL = malloc(N * sizeof(double));
        for (NSUInteger k = 0; k < N; k++) {
            mzL[k] = 100.0 + (double)k * 0.5;
            inL[k] = 1000.0 + (double)k;
        }
        NSString *xml = buildSyntheticMzML(mzL, inL, N, mz2, in2, 2, tt, ti, 5, YES);
        free(mzL); free(inL);
        NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];

        NSDate *t0 = [NSDate date];
        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOMzMLReader readFromData:data error:&err];
        NSTimeInterval dt = -[t0 timeIntervalSinceNow];
        PASS(ds != nil, "100-peak synthetic parses");
        printf("    [bench] 100-peak synthetic mzML parse %.2f ms\n", dt * 1000.0);
    }

    // ---- real HUPO-PSI fixtures (if present) ----
    {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *candidates = @[
            @"Fixtures/tiny.pwiz.1.1.mzML",
            @"../Fixtures/tiny.pwiz.1.1.mzML",
            @"Tests/Fixtures/tiny.pwiz.1.1.mzML",
            @"../Tests/Fixtures/tiny.pwiz.1.1.mzML",
        ];
        NSString *tinyPath = nil;
        for (NSString *p in candidates) {
            if ([fm fileExistsAtPath:p]) { tinyPath = p; break; }
        }

        if (!tinyPath) {
            printf("    [skip] HUPO-PSI fixtures not found in CWD (non-fatal)\n");
        } else {
            NSError *err = nil;

            // tiny.pwiz.1.1.mzML: 4 spectra, 2 chromatograms
            NSDate *t0 = [NSDate date];
            MPGOMzMLReader *r = [MPGOMzMLReader parseFilePath:tinyPath error:&err];
            NSTimeInterval dt = -[t0 timeIntervalSinceNow];
            PASS(r != nil, "tiny.pwiz.1.1.mzML parses");
            PASS(err == nil, "tiny.pwiz.1.1.mzML has no parse error");
            PASS(r.dataset != nil, "tiny.pwiz.1.1 dataset materialized");

            MPGOAcquisitionRun *run = [r.dataset.msRuns.allValues firstObject];
            PASS(run != nil, "tiny.pwiz.1.1 has at least one run");

            NSUInteger msCount = run.spectrumIndex.count;
            PASS(msCount > 0, "tiny.pwiz.1.1 exposes one or more mass spectra");

            // chromatograms come out via the instance API
            PASS(r.chromatograms.count == 2, "tiny.pwiz.1.1 has 2 chromatograms");

            printf("    [bench] tiny.pwiz.1.1.mzML (25 KB) parse %.2f ms\n",
                   dt * 1000.0);

            // Spot check MS level + polarity on the first spectrum
            MPGOMassSpectrum *first = [run spectrumAtIndex:0 error:&err];
            PASS(first != nil, "first spectrum retrievable");
            PASS(first.msLevel >= 1 && first.msLevel <= 3, "ms level in sane range");

            // Full round trip to .mpgo
            NSString *path = mpath(@"tiny_real");
            unlink([path fileSystemRepresentation]);
            PASS([r.dataset writeToFilePath:path error:&err],
                 "tiny.pwiz.1.1 writes to .mpgo");
            MPGOSpectralDataset *back =
                [MPGOSpectralDataset readFromFilePath:path error:&err];
            PASS(back != nil, "tiny.pwiz.1.1 .mpgo reads back");
            MPGOAcquisitionRun *backRun = [back.msRuns.allValues firstObject];
            PASS(backRun != nil, "round-trip run recovered");
            unlink([path fileSystemRepresentation]);
        }

        // 1min.mzML fixture: 39 spectra, real instrument data
        NSArray *oneMinCandidates = @[
            @"Fixtures/1min.mzML",
            @"../Fixtures/1min.mzML",
            @"Tests/Fixtures/1min.mzML",
            @"../Tests/Fixtures/1min.mzML",
        ];
        NSString *oneMinPath = nil;
        for (NSString *p in oneMinCandidates) {
            if ([fm fileExistsAtPath:p]) { oneMinPath = p; break; }
        }

        if (oneMinPath) {
            NSError *err = nil;
            NSDate *t0 = [NSDate date];
            MPGOSpectralDataset *ds =
                [MPGOMzMLReader readFromFilePath:oneMinPath error:&err];
            NSTimeInterval dt = -[t0 timeIntervalSinceNow];
            PASS(ds != nil, "1min.mzML parses");
            PASS(err == nil, "1min.mzML has no parse error");

            MPGOAcquisitionRun *run = [ds.msRuns.allValues firstObject];
            PASS(run != nil, "1min.mzML has a run");

            NSUInteger count = run.spectrumIndex.count;
            PASS(count > 0, "1min.mzML exposes spectra");
            printf("    [bench] 1min.mzML (311 KB, %lu spectra) parse %.2f ms\n",
                   (unsigned long)count, dt * 1000.0);
        }
    }
}

// M74: verify reader pulls activation method + isolation window from
// tiny.pwiz.1.1.mzML and surfaces them through the run's SpectrumIndex.
void testMzMLReaderM74(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = @[
        @"Fixtures/tiny.pwiz.1.1.mzML",
        @"../Fixtures/tiny.pwiz.1.1.mzML",
        @"Tests/Fixtures/tiny.pwiz.1.1.mzML",
        @"../Tests/Fixtures/tiny.pwiz.1.1.mzML",
    ];
    NSString *tinyPath = nil;
    for (NSString *p in candidates) {
        if ([fm fileExistsAtPath:p]) { tinyPath = p; break; }
    }
    if (!tinyPath) {
        printf("    [skip] tiny.pwiz.1.1.mzML not found (M74 test non-fatal)\n");
        return;
    }

    NSError *err = nil;
    MPGOSpectralDataset *ds =
        [MPGOMzMLReader readFromFilePath:tinyPath error:&err];
    PASS(ds != nil, "tiny.pwiz.1.1.mzML parses for M74 check");
    MPGOAcquisitionRun *run = [ds.msRuns.allValues firstObject];
    PASS(run != nil, "run present");

    MPGOSpectrumIndex *idx = run.spectrumIndex;
    PASS(idx.hasActivationDetail, "index has M74 activation-detail columns");

    // tiny.pwiz.1.1.mzML: MS2 scans 2 and 4 both use CID with target 445.3
    // and 0.5/0.5 offsets. Find the first MS2 and verify.
    NSInteger ms2Found = -1;
    for (NSUInteger i = 0; i < idx.count; i++) {
        if ([idx msLevelAt:i] == 2) { ms2Found = (NSInteger)i; break; }
    }
    PASS(ms2Found >= 0, "at least one MS2 present");
    if (ms2Found >= 0) {
        NSUInteger i = (NSUInteger)ms2Found;
        PASS([idx activationMethodAt:i] == MPGOActivationMethodCID,
             "MS2 activation method is CID");
        MPGOIsolationWindow *iw = [idx isolationWindowAt:i];
        PASS(iw != nil, "MS2 isolation window present");
        PASS(iw != nil && fabs(iw.targetMz - 445.3) < 1e-9,
             "MS2 isolation target m/z = 445.3");
        PASS(iw != nil && fabs(iw.lowerOffset - 0.5) < 1e-9,
             "MS2 isolation lower offset = 0.5");
        PASS(iw != nil && fabs(iw.upperOffset - 0.5) < 1e-9,
             "MS2 isolation upper offset = 0.5");
    }

    // MS1 rows should round-trip as None/no-window.
    NSInteger ms1Found = -1;
    for (NSUInteger i = 0; i < idx.count; i++) {
        if ([idx msLevelAt:i] == 1) { ms1Found = (NSInteger)i; break; }
    }
    if (ms1Found >= 0) {
        NSUInteger i = (NSUInteger)ms1Found;
        PASS([idx activationMethodAt:i] == MPGOActivationMethodNone,
             "MS1 activation method is None");
        PASS([idx isolationWindowAt:i] == nil,
             "MS1 isolation window is nil");
    }

    // Full round-trip through .mpgo: M74 columns must survive.
    NSString *path = mpath(@"m74_roundtrip");
    unlink([path fileSystemRepresentation]);
    PASS([ds writeToFilePath:path error:&err], "M74 write to .mpgo");
    MPGOSpectralDataset *back =
        [MPGOSpectralDataset readFromFilePath:path error:&err];
    PASS(back != nil, "M74 .mpgo reads back");
    MPGOAcquisitionRun *backRun = [back.msRuns.allValues firstObject];
    MPGOSpectrumIndex *backIdx = backRun.spectrumIndex;
    PASS(backIdx.hasActivationDetail, "M74 columns survive round-trip");
    if (ms2Found >= 0) {
        NSUInteger i = (NSUInteger)ms2Found;
        PASS([backIdx activationMethodAt:i] == MPGOActivationMethodCID,
             "post-round-trip MS2 activation method still CID");
        MPGOIsolationWindow *iw = [backIdx isolationWindowAt:i];
        PASS(iw && fabs(iw.targetMz - 445.3) < 1e-9,
             "post-round-trip isolation target survives");
    }
    unlink([path fileSystemRepresentation]);
}
