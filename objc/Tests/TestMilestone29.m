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
#import <sys/stat.h>
#import <stdlib.h>
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
        // v0.9 M64 canonical nmrML: cvParams inside acquisitionParameterSet
        // are no longer XSD-valid; spectrometer frequency + sweep width are
        // now emitted as <irradiationFrequency> + <sweepWidth> elements
        // inside DirectDimensionParameterSet.
        PASS([str rangeOfString:@"<irradiationFrequency"].location != NSNotFound,
             "M29: output contains <irradiationFrequency>");
        PASS([str rangeOfString:@"NMR:1000002"].location != NSNotFound,
             "M29: output contains NMR:1000002 (acquisition nucleus)");
        PASS([str rangeOfString:@"<sweepWidth"].location != NSNotFound,
             "M29: output contains <sweepWidth>");
        PASS([str rangeOfString:@"<spectrum1D"].location != NSNotFound,
             "M29: output contains <spectrum1D");
        PASS([str rangeOfString:@"<xAxis"].location != NSNotFound,
             "M29: output contains <xAxis (attribute-only)");
        // v0.9 M64 XSD-required wrapper sections:
        PASS([str rangeOfString:@"version=\"1.1.0\""].location != NSNotFound,
             "M29: <nmrML> carries version='1.1.0' attr (XSD-required)");
        PASS([str rangeOfString:@"<fileDescription>"].location != NSNotFound,
             "M29: <fileDescription> required before <acquisition>");
        PASS([str rangeOfString:@"<softwareList>"].location != NSNotFound,
             "M29: <softwareList> required before <acquisition>");
        PASS([str rangeOfString:@"<instrumentConfigurationList>"].location != NSNotFound,
             "M29: <instrumentConfigurationList> required before <acquisition>");
        PASS([str rangeOfString:@"<DirectDimensionParameterSet"].location != NSNotFound,
             "M29: <DirectDimensionParameterSet> required inside acquisition1D");
        PASS([str rangeOfString:@"<sampleContainer"].location != NSNotFound,
             "M29: <sampleContainer> required in acquisitionParameterSet");
        PASS([str rangeOfString:@"byteFormat="].location != NSNotFound,
             "M29: BinaryDataArrayType byteFormat attr required by XSD");
        PASS([str rangeOfString:@"numberOfDataPoints="].location != NSNotFound,
             "M29: <spectrum1D> numberOfDataPoints attr required by XSD");
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

    // ---- Thermo RAW reader rejects missing input file (M38) ----
    // M29 stub returned nil unconditionally; M38 replaced it with a real
    // ThermoRawFileParser delegation that validates the input first.
    {
        NSError *err = nil;
        id result = [MPGOThermoRawReader readFromFilePath:
                @"/tmp/definitely-does-not-exist-mpgo-m38.raw" error:&err];
        PASS(result == nil, "M38: Thermo reader returns nil for missing file");
        PASS(err != nil, "M38: Thermo reader populates NSError for missing file");
    }

    // ---- M38: end-to-end delegation via mock binary ----
    {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *cwd = [fm currentDirectoryPath];
        NSString *fixtureAbs = [cwd stringByAppendingPathComponent:
                                @"Tests/Fixtures/tiny.pwiz.1.1.mzML"];
        if (![fm fileExistsAtPath:fixtureAbs]) {
            fixtureAbs = [cwd stringByAppendingPathComponent:
                         @"objc/Tests/Fixtures/tiny.pwiz.1.1.mzML"];
        }

        NSString *tmpDir = m29TempPath(@"thermodir");
        [fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES
                       attributes:nil error:NULL];

        NSString *mockScript = [tmpDir stringByAppendingPathComponent:@"mock-parser"];
        NSString *shellScript = [NSString stringWithFormat:
            @"#!/usr/bin/env bash\n"
            @"set -e\n"
            @"while [ $# -gt 0 ]; do\n"
            @"  case \"$1\" in\n"
            @"    -i) in_path=\"$2\"; shift 2;;\n"
            @"    -o) out_dir=\"$2\"; shift 2;;\n"
            @"    -f) shift 2;;\n"
            @"    *) shift;;\n"
            @"  esac\n"
            @"done\n"
            @"base=$(basename \"$in_path\" .raw)\n"
            @"cp %@ \"$out_dir/$base.mzML\"\n", fixtureAbs];
        [shellScript writeToFile:mockScript atomically:YES
                         encoding:NSUTF8StringEncoding error:NULL];
        chmod([mockScript fileSystemRepresentation], 0755);

        NSString *rawPath = [tmpDir stringByAppendingPathComponent:@"sample.raw"];
        [@"fake raw bytes" writeToFile:rawPath atomically:YES
                              encoding:NSUTF8StringEncoding error:NULL];

        setenv("THERMORAWFILEPARSER", [mockScript fileSystemRepresentation], 1);
        NSError *err = nil;
        id result = [MPGOThermoRawReader readFromFilePath:rawPath error:&err];
        unsetenv("THERMORAWFILEPARSER");

        PASS(result != nil, "M38: Thermo reader returns dataset via mock binary");
        PASS(err == nil, "M38: no error when mock binary succeeds");

        [fm removeItemAtPath:tmpDir error:NULL];
    }
}
