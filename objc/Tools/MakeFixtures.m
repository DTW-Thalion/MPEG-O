// MakeFixtures — one-shot generator for the canonical v0.2 .mpgo
// reference fixtures under objc/Tests/Fixtures/mpgo/. Rebuilds the
// files deterministically (modulo HDF5 timestamps) so third-party
// readers can smoke-test their implementations.
//
// Build:    make -C objc/Tools
// Run:      objc/Tools/obj/MakeFixtures <output_dir>
//
// Typical usage: run from repo root with output_dir =
// objc/Tests/Fixtures/mpgo, then commit the resulting files.

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Run/MPGOAcquisitionRun.h"
#import "Run/MPGOInstrumentConfig.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOQuantification.h"
#import "Dataset/MPGOProvenanceRecord.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "Protection/MPGOEncryptionManager.h"
#import "Protection/MPGOSignatureManager.h"

static MPGOSignalArray *f64(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static MPGOInstrumentConfig *emptyCfg(void)
{
    return [[MPGOInstrumentConfig alloc] initWithManufacturer:@"example"
                                                        model:@"MPEG-O"
                                                 serialNumber:@"0000"
                                                   sourceType:@""
                                                 analyzerType:@""
                                                 detectorType:@""];
}

static MPGOAcquisitionRun *buildMSRun(NSUInteger nSpectra, NSUInteger peaksPerSpec)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < nSpectra; k++) {
        double *mz = malloc(peaksPerSpec * sizeof(double));
        double *in = malloc(peaksPerSpec * sizeof(double));
        for (NSUInteger i = 0; i < peaksPerSpec; i++) {
            mz[i] = 100.0 + (double)i * 0.5 + (double)k * 0.01;
            in[i] = 1000.0 + (double)(k * 10 + i);
        }
        MPGOSignalArray *mzA = f64(mz, peaksPerSpec);
        MPGOSignalArray *inA = f64(in, peaksPerSpec);
        free(mz); free(in);
        [spectra addObject:
            [[MPGOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:(k % 3 == 0 ? 1 : 2)
                                             polarity:MPGOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:k
                                      scanTimeSeconds:(double)k * 0.1
                                          precursorMz:(k % 3 == 0 ? 0 : 450.0 + (double)k)
                                      precursorCharge:(k % 3 == 0 ? 0 : 2)
                                                error:NULL]];
    }
    return [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:MPGOAcquisitionModeMS1DDA
                                      instrumentConfig:emptyCfg()];
}

static MPGOAcquisitionRun *buildNMRRun(NSUInteger nSpectra, NSUInteger points)
{
    NSMutableArray *spectra = [NSMutableArray array];
    for (NSUInteger k = 0; k < nSpectra; k++) {
        double *cs  = malloc(points * sizeof(double));
        double *ins = malloc(points * sizeof(double));
        for (NSUInteger i = 0; i < points; i++) {
            cs[i]  = -1.0 + (double)i * (12.0 / (double)points);
            ins[i] = 1000.0 + (double)(k * 10 + i);
        }
        MPGOSignalArray *csA = f64(cs, points);
        MPGOSignalArray *inA = f64(ins, points);
        free(cs); free(ins);
        [spectra addObject:
            [[MPGONMRSpectrum alloc]
                initWithChemicalShiftArray:csA
                            intensityArray:inA
                               nucleusType:@"1H"
                  spectrometerFrequencyMHz:600.13
                             indexPosition:k
                           scanTimeSeconds:(double)k * 0.5
                                     error:NULL]];
    }
    return [[MPGOAcquisitionRun alloc] initWithSpectra:spectra
                                       acquisitionMode:MPGOAcquisitionMode1DNMR
                                      instrumentConfig:emptyCfg()];
}

static NSData *makeKey(void)
{
    uint8_t raw[32];
    for (int i = 0; i < 32; i++) raw[i] = (uint8_t)(0xA5 ^ (i * 3));
    return [NSData dataWithBytes:raw length:32];
}

static BOOL writeMinimalMS(NSString *path)
{
    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"minimal MS"
                                isaInvestigationId:@"MPGO:minimal"
                                            msRuns:@{@"run_0001": buildMSRun(10, 8)}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    return [ds writeToFilePath:path error:NULL];
}

static BOOL writeFullMS(NSString *path)
{
    NSMutableArray *idents = [NSMutableArray array];
    for (NSUInteger i = 0; i < 10; i++) {
        [idents addObject:
            [[MPGOIdentification alloc]
                initWithRunName:@"run_0001"
                  spectrumIndex:i
                 chemicalEntity:[NSString stringWithFormat:@"CHEBI:%lu",
                                 (unsigned long)(15000 + i)]
                confidenceScore:0.5 + (double)i * 0.04
                  evidenceChain:@[@"MS:1002217", @"PRIDE:0000033"]]];
    }
    NSMutableArray *quants = [NSMutableArray array];
    for (NSUInteger i = 0; i < 5; i++) {
        [quants addObject:
            [[MPGOQuantification alloc]
                initWithChemicalEntity:[NSString stringWithFormat:@"CHEBI:%lu",
                                        (unsigned long)(15000 + i)]
                             sampleRef:@"sample_A"
                             abundance:1000.0 * (double)(i + 1)
                   normalizationMethod:@"median"]];
    }
    NSArray *prov = @[
        [[MPGOProvenanceRecord alloc] initWithInputRefs:@[@"raw:ABC123.raw"]
                                               software:@"msconvert"
                                             parameters:@{@"peak-picking": @YES}
                                             outputRefs:@[@"mzml:ABC123.mzML"]
                                          timestampUnix:1700000000],
        [[MPGOProvenanceRecord alloc] initWithInputRefs:@[@"mzml:ABC123.mzML"]
                                               software:@"mpgo-import"
                                             parameters:@{}
                                             outputRefs:@[@"mpgo:ABC123.mpgo"]
                                          timestampUnix:1700000300],
    ];
    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"full MS with annotations"
                                isaInvestigationId:@"MPGO:full"
                                            msRuns:@{@"run_0001": buildMSRun(12, 8)}
                                           nmrRuns:@{}
                                   identifications:idents
                                   quantifications:quants
                                 provenanceRecords:prov
                                       transitions:nil];
    return [ds writeToFilePath:path error:NULL];
}

static BOOL writeNMR1D(NSString *path)
{
    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"NMR 1D example"
                                isaInvestigationId:@"MPGO:nmr1d"
                                            msRuns:@{@"nmr_run": buildNMRRun(5, 64)}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    return [ds writeToFilePath:path error:NULL];
}

static BOOL writeEncrypted(NSString *path)
{
    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"encrypted example"
                                isaInvestigationId:@"MPGO:enc"
                                            msRuns:@{@"run_0001": buildMSRun(10, 8)}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    if (![ds writeToFilePath:path error:NULL]) return NO;
    return [ds encryptWithKey:makeKey()
                        level:MPGOEncryptionLevelDataset
                        error:NULL];
}

static BOOL writeSigned(NSString *path)
{
    MPGOSpectralDataset *ds =
        [[MPGOSpectralDataset alloc] initWithTitle:@"signed example"
                                isaInvestigationId:@"MPGO:signed"
                                            msRuns:@{@"run_0001": buildMSRun(10, 8)}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    if (![ds writeToFilePath:path error:NULL]) return NO;
    NSData *key = makeKey();
    NSString *mzPath = @"/study/ms_runs/run_0001/signal_channels/mz_values";
    NSString *intPath = @"/study/ms_runs/run_0001/signal_channels/intensity_values";
    if (![MPGOSignatureManager signDataset:mzPath inFile:path withKey:key error:NULL])
        return NO;
    if (![MPGOSignatureManager signDataset:intPath inFile:path withKey:key error:NULL])
        return NO;
    return YES;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: MakeFixtures <output_dir>\n");
            return 2;
        }
        NSString *dir = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];

        struct { const char *name; BOOL (*fn)(NSString *); } items[] = {
            { "minimal_ms.mpgo", writeMinimalMS },
            { "full_ms.mpgo",    writeFullMS },
            { "nmr_1d.mpgo",     writeNMR1D },
            { "encrypted.mpgo",  writeEncrypted },
            { "signed.mpgo",     writeSigned },
        };
        for (int i = 0; i < 5; i++) {
            NSString *out = [dir stringByAppendingPathComponent:
                             [NSString stringWithUTF8String:items[i].name]];
            unlink([out fileSystemRepresentation]);
            BOOL ok = items[i].fn(out);
            fprintf(stdout, "  %s %s\n",
                    ok ? "wrote" : "FAILED",
                    [out UTF8String]);
            if (!ok) return 1;
        }
    }
    return 0;
}
