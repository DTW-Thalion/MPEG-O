#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Import/TTIONmrMLReader.h"
#import "Core/TTIOSignalArray.h"
#import "Spectra/TTIOFreeInductionDecay.h"
#import "Spectra/TTIONMRSpectrum.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "ValueClasses/TTIOEnums.h"
#import <math.h>
#import <unistd.h>

static NSString *m13path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m13_%d_%@.tio",
            (int)getpid(), suffix];
}

static NSString *base64Doubles(const double *v, NSUInteger n)
{
    NSData *d = [NSData dataWithBytes:v length:n * sizeof(double)];
    return [d base64EncodedStringWithOptions:0];
}

static NSString *buildNmrML(const double *fidBuf, NSUInteger complexLen,
                             const double *csBuf, const double *intBuf, NSUInteger specLen)
{
    NSString *fidB64 = base64Doubles(fidBuf, complexLen * 2);  // real+imag
    NSString *csB64  = base64Doubles(csBuf, specLen);
    NSString *intB64 = base64Doubles(intBuf, specLen);

    return [NSString stringWithFormat:
@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
@"<nmrML xmlns=\"http://nmrml.org/schema\" version=\"1.0.2\" id=\"synthetic\">\n"
@"  <cvList><cv id=\"NMR\" fullName=\"nmrCV\" URI=\"\"/></cvList>\n"
@"  <acquisition>\n"
@"    <acquisition1D>\n"
@"      <acquisitionParameterSet>\n"
@"        <cvParam cvRef=\"NMR\" accession=\"NMR:1000001\" name=\"spectrometer frequency\" value=\"600.13\"/>\n"
@"        <cvParam cvRef=\"NMR\" accession=\"NMR:1000002\" name=\"nucleus\" value=\"1H\"/>\n"
@"        <cvParam cvRef=\"NMR\" accession=\"NMR:1400014\" name=\"sweep width\" value=\"16.0\"/>\n"
@"        <cvParam cvRef=\"NMR\" accession=\"NMR:1000003\" name=\"number of scans\" value=\"128\"/>\n"
@"        <cvParam cvRef=\"NMR\" accession=\"NMR:1000004\" name=\"dwell time\" value=\"0.0001\"/>\n"
@"      </acquisitionParameterSet>\n"
@"      <fidData compressed=\"false\" byteFormat=\"float64\">%@</fidData>\n"
@"    </acquisition1D>\n"
@"  </acquisition>\n"
@"  <spectrumList count=\"1\">\n"
@"    <spectrum1D id=\"proc_1\">\n"
@"      <xAxis><spectrumDataArray compressed=\"false\">%@</spectrumDataArray></xAxis>\n"
@"      <yAxis><spectrumDataArray compressed=\"false\">%@</spectrumDataArray></yAxis>\n"
@"    </spectrum1D>\n"
@"  </spectrumList>\n"
@"</nmrML>\n",
        fidB64, csB64, intB64];
}

static BOOL complexBuffersEqual(NSData *buf, const double *expected, NSUInteger complexLen)
{
    if (buf.length != complexLen * 2 * sizeof(double)) return NO;
    const double *got = buf.bytes;
    for (NSUInteger i = 0; i < complexLen * 2; i++) {
        if (fabs(got[i] - expected[i]) > 1e-9) return NO;
    }
    return YES;
}

void testMilestone13(void)
{
    // ---- 1. Synthetic FID + spectrum1D round-trip ----
    const NSUInteger N = 64;
    double *fid = malloc(N * 2 * sizeof(double));
    for (NSUInteger i = 0; i < N; i++) {
        double t = (double)i * 1e-4;
        fid[2 * i]     = exp(-t * 5.0) * cos(t * 1000.0);
        fid[2 * i + 1] = exp(-t * 5.0) * sin(t * 1000.0);
    }
    const NSUInteger M = 32;
    double *cs  = malloc(M * sizeof(double));
    double *ins = malloc(M * sizeof(double));
    for (NSUInteger i = 0; i < M; i++) {
        cs[i]  = -1.0 + (double)i * 0.1;
        ins[i] = sin((double)i * 0.2) * 500.0;
    }

    {
        NSString *xml = buildNmrML(fid, N, cs, ins, M);
        NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];

        NSError *err = nil;
        TTIONmrMLReader *r = [TTIONmrMLReader parseData:data error:&err];
        PASS(r != nil, "nmrML parseData returns reader");
        PASS(err == nil, "nmrML parse no error");

        // Acquisition parameters
        PASS(fabs(r.spectrometerFrequencyMHz - 600.13) < 1e-9,
             "spectrometer frequency parsed");
        PASS([r.nucleusType isEqualToString:@"1H"], "nucleus parsed");
        PASS(r.numberOfScans == 128, "number of scans parsed");
        PASS(fabs(r.dwellTimeSeconds - 0.0001) < 1e-12, "dwell time parsed");
        PASS(fabs(r.sweepWidthPpm - 16.0) < 1e-9, "sweep width parsed");

        // FID
        PASS(r.fids.count == 1, "one FID parsed");
        TTIOFreeInductionDecay *f = r.fids[0];
        PASS(f.length == N, "FID complex length matches");
        PASS(complexBuffersEqual(f.buffer, fid, N), "FID real+imag match reference");
        PASS(fabs(f.dwellTimeSeconds - 0.0001) < 1e-12,
             "FID dwell time populated from acquisition");
        PASS(f.scanCount == 128, "FID scan count populated");

        // Processed spectrum1D
        TTIOAcquisitionRun *run = r.dataset.msRuns[@"nmr_run"];
        PASS(run != nil, "nmr_run wrapped in dataset");
        PASS(run.count == 1, "one processed spectrum");
        TTIONMRSpectrum *spec = [run spectrumAtIndex:0 error:&err];
        PASS([spec isKindOfClass:[TTIONMRSpectrum class]],
             "spectrum1D materializes as TTIONMRSpectrum");
        PASS(spec.chemicalShiftArray.length == M, "cs array length");
        PASS(spec.intensityArray.length == M, "intensity array length");
        PASS([spec.nucleusType isEqualToString:@"1H"],
             "spectrum carries nucleus from acquisition");

        const double *gotCs  = spec.chemicalShiftArray.buffer.bytes;
        const double *gotIn  = spec.intensityArray.buffer.bytes;
        BOOL csMatch = YES, inMatch = YES;
        for (NSUInteger i = 0; i < M; i++) {
            if (fabs(gotCs[i] - cs[i]) > 1e-9) csMatch = NO;
            if (fabs(gotIn[i] - ins[i]) > 1e-9) inMatch = NO;
        }
        PASS(csMatch, "chemical shift bytes match reference");
        PASS(inMatch, "intensity bytes match reference");
    }

    // ---- 2. Round-trip: nmrML -> TTIO -> .tio -> read back ----
    {
        NSString *xml = buildNmrML(fid, N, cs, ins, M);
        NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        TTIOSpectralDataset *ds =
            [TTIONmrMLReader readFromData:data error:&err];
        PASS(ds != nil, "readFromData returns dataset");

        NSString *path = m13path(@"roundtrip");
        unlink([path fileSystemRepresentation]);
        PASS([ds writeToFilePath:path error:&err], "dataset writes .tio");

        TTIOSpectralDataset *back =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        PASS(back != nil, ".tio reads back");
        TTIOAcquisitionRun *run = back.msRuns[@"nmr_run"];
        PASS(run != nil, "nmr_run survives round-trip");
        TTIONMRSpectrum *spec = [run spectrumAtIndex:0 error:&err];
        PASS([spec isKindOfClass:[TTIONMRSpectrum class]],
             "round-trip spectrum is NMR");
        PASS(spec.chemicalShiftArray.length == M,
             "round-trip cs length preserved");
        [back closeFile];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 3. Malformed XML ----
    {
        NSString *bad = @"<?xml version=\"1.0\"?><nmrML><acquisition><fidData>not-base64</";
        NSError *err = nil;
        TTIOSpectralDataset *ds =
            [TTIONmrMLReader readFromData:[bad dataUsingEncoding:NSUTF8StringEncoding]
                                    error:&err];
        PASS(ds == nil, "malformed nmrML returns nil");
        PASS(err != nil, "malformed nmrML populates NSError");
    }

    free(fid); free(cs); free(ins);

    // ---- 4. Real HUPO/BMRB fixture (bmse000325.nmrML) ----
    {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *candidates = @[
            @"Fixtures/bmse000325.nmrML",
            @"../Fixtures/bmse000325.nmrML",
            @"Tests/Fixtures/bmse000325.nmrML",
            @"../Tests/Fixtures/bmse000325.nmrML",
        ];
        NSString *fixturePath = nil;
        for (NSString *p in candidates) {
            if ([fm fileExistsAtPath:p]) { fixturePath = p; break; }
        }
        if (!fixturePath) {
            printf("    [skip] bmse000325.nmrML fixture not found in CWD (non-fatal)\n");
        } else {
            NSError *err = nil;
            NSDate *t0 = [NSDate date];
            TTIONmrMLReader *r = [TTIONmrMLReader parseFilePath:fixturePath error:&err];
            NSTimeInterval dt = -[t0 timeIntervalSinceNow];
            PASS(r != nil, "bmse000325.nmrML parses");
            PASS(err == nil, "bmse000325.nmrML has no parse error");

            // acquisitionParameterSet numberOfScans="4"
            PASS(r.numberOfScans == 4, "bmse numberOfScans = 4");
            // acquisitionNucleus name="hydrogen atom" -> "1H"
            PASS([r.nucleusType isEqualToString:@"1H"],
                 "bmse nucleus mapped to 1H");
            // irradiationFrequency = 4.9984E8 Hz -> 499.84 MHz
            PASS(fabs(r.spectrometerFrequencyMHz - 499.84) < 0.1,
                 "bmse irradiationFrequency parsed to ~499.84 MHz");
            // sweepWidth 7002.80... Hz
            PASS(r.sweepWidthPpm > 7000 && r.sweepWidthPpm < 7010,
                 "bmse sweepWidth in expected range");

            // fidData encodedLength=32768 int32 samples -> 16384 complex
            PASS(r.fids.count == 1, "bmse has exactly one FID");
            TTIOFreeInductionDecay *f = r.fids[0];
            PASS(f.length == 16384, "bmse FID length = 16384 complex samples");
            PASS(f.scanCount == 4, "bmse FID inherits scan count");
            PASS(f.buffer.length == 16384 * 2 * sizeof(double),
                 "bmse FID buffer widened to float64 complex");
            printf("    [bench] bmse000325.nmrML (176 KB) parse %.2f ms\n",
                   dt * 1000.0);
        }
    }
}
