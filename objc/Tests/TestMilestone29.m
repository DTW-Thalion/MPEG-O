// Milestone 29: nmrML writer + Thermo RAW stub.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Spectra/MPGOFreeInductionDecay.h"
#import "Export/MPGONmrMLWriter.h"
#import "Import/MPGONmrMLReader.h"
#import "Import/MPGOThermoRawReader.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>
#import <math.h>

static NSString *m29TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m29_%d_%@",
            (int)getpid(), suffix];
}

static MPGOSignalArray *m29Array(const double *v, NSUInteger n)
{
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    NSData *d = [NSData dataWithBytes:v length:n * sizeof(double)];
    return [[MPGOSignalArray alloc] initWithBuffer:d length:n encoding:enc axis:nil];
}

void testMilestone29(void)
{
    // ---- nmrML writer produces valid XML ----
    {
        double cs[] = { 0.0, 1.0, 2.0, 3.0, 4.0 };
        double it[] = { 100.0, 200.0, 300.0, 200.0, 100.0 };
        MPGONMRSpectrum *spec =
            [[MPGONMRSpectrum alloc] initWithChemicalShiftArray:m29Array(cs, 5)
                                                  intensityArray:m29Array(it, 5)
                                                     nucleusType:@"1H"
                                        spectrometerFrequencyMHz:600.0
                                                   indexPosition:0
                                                 scanTimeSeconds:0.0
                                                           error:NULL];
        PASS(spec != nil, "M29: NMRSpectrum created");

        NSError *err = nil;
        NSData *xml = [MPGONmrMLWriter dataForSpectrum:spec
                                                    fid:nil
                                          sweepWidthPPM:12.0
                                                  error:&err];
        PASS(xml.length > 0, "M29: nmrML writer produces non-empty output");

        NSString *str = [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
        PASS([str rangeOfString:@"<nmrML"].location != NSNotFound,
             "M29: output contains <nmrML> root");
        PASS([str rangeOfString:@"NMR:1000001"].location != NSNotFound,
             "M29: output contains spectrometer frequency cvParam");
        PASS([str rangeOfString:@"NMR:1000002"].location != NSNotFound,
             "M29: output contains nucleus cvParam");
        PASS([str rangeOfString:@"NMR:1400014"].location != NSNotFound,
             "M29: output contains sweep width cvParam");
        PASS([str rangeOfString:@"<spectrum1D>"].location != NSNotFound,
             "M29: output contains <spectrum1D>");
        PASS([str rangeOfString:@"<xAxis>"].location != NSNotFound,
             "M29: output contains <xAxis>");
    }

    // ---- nmrML round-trip via reader ----
    {
        double cs[] = { 0.5, 1.5, 2.5, 3.5 };
        double it[] = { 10.0, 20.0, 30.0, 20.0 };
        MPGONMRSpectrum *spec =
            [[MPGONMRSpectrum alloc] initWithChemicalShiftArray:m29Array(cs, 4)
                                                  intensityArray:m29Array(it, 4)
                                                     nucleusType:@"1H"
                                        spectrometerFrequencyMHz:400.0
                                                   indexPosition:0
                                                 scanTimeSeconds:0.0
                                                           error:NULL];
        NSString *path = m29TempPath(@"rt.nmrML");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([MPGONmrMLWriter writeSpectrum:spec fid:nil
                              sweepWidthPPM:10.0 toPath:path error:&err],
             "M29: nmrML writes to disk");

        MPGONmrMLReader *reader = [MPGONmrMLReader parseFilePath:path error:&err];
        PASS(reader != nil, "M29: nmrML reader parses writer output");
        PASS([reader.nucleusType isEqualToString:@"1H"],
             "M29: reader recovered nucleus type 1H");
        PASS(reader.spectrometerFrequencyMHz > 0.0,
             "M29: reader recovered nonzero spectrometer frequency");
        PASS(reader.sweepWidthPpm > 0.0,
             "M29: reader recovered nonzero sweep width");
        PASS(reader.dataset != nil, "M29: reader produced a dataset");

        unlink([path fileSystemRepresentation]);
    }

    // ---- Thermo RAW stub returns nil + error ----
    {
        NSError *err = nil;
        id result = [MPGOThermoRawReader readFromFilePath:@"/tmp/fake.raw" error:&err];
        PASS(result == nil, "M29: Thermo stub returns nil");
        PASS(err != nil, "M29: Thermo stub populates NSError");
        PASS([err.localizedDescription rangeOfString:@"not yet implemented"].location != NSNotFound,
             "M29: Thermo error message mentions not-yet-implemented");
    }
}
