#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Import/MPGONmrMLReader.h"
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGOFreeInductionDecay.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOSpectrumIndex.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "ValueClasses/MPGOEnums.h"
#import <math.h>
#import <unistd.h>

static NSString *m13path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m13_%d_%@.mpgo",
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
        MPGONmrMLReader *r = [MPGONmrMLReader parseData:data error:&err];
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
        MPGOFreeInductionDecay *f = r.fids[0];
        PASS(f.length == N, "FID complex length matches");
        PASS(complexBuffersEqual(f.buffer, fid, N), "FID real+imag match reference");
        PASS(fabs(f.dwellTimeSeconds - 0.0001) < 1e-12,
             "FID dwell time populated from acquisition");
        PASS(f.scanCount == 128, "FID scan count populated");

        // Processed spectrum1D
        MPGOAcquisitionRun *run = r.dataset.msRuns[@"nmr_run"];
        PASS(run != nil, "nmr_run wrapped in dataset");
        PASS(run.count == 1, "one processed spectrum");
        MPGONMRSpectrum *spec = [run spectrumAtIndex:0 error:&err];
        PASS([spec isKindOfClass:[MPGONMRSpectrum class]],
             "spectrum1D materializes as MPGONMRSpectrum");
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

    // ---- 2. Round-trip: nmrML -> MPGO -> .mpgo -> read back ----
    {
        NSString *xml = buildNmrML(fid, N, cs, ins, M);
        NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        MPGOSpectralDataset *ds =
            [MPGONmrMLReader readFromData:data error:&err];
        PASS(ds != nil, "readFromData returns dataset");

        NSString *path = m13path(@"roundtrip");
        unlink([path fileSystemRepresentation]);
        PASS([ds writeToFilePath:path error:&err], "dataset writes .mpgo");

        MPGOSpectralDataset *back =
            [MPGOSpectralDataset readFromFilePath:path error:&err];
        PASS(back != nil, ".mpgo reads back");
        MPGOAcquisitionRun *run = back.msRuns[@"nmr_run"];
        PASS(run != nil, "nmr_run survives round-trip");
        MPGONMRSpectrum *spec = [run spectrumAtIndex:0 error:&err];
        PASS([spec isKindOfClass:[MPGONMRSpectrum class]],
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
        MPGOSpectralDataset *ds =
            [MPGONmrMLReader readFromData:[bad dataUsingEncoding:NSUTF8StringEncoding]
                                    error:&err];
        PASS(ds == nil, "malformed nmrML returns nil");
        PASS(err != nil, "malformed nmrML populates NSError");
    }

    free(fid); free(cs); free(ins);
}
