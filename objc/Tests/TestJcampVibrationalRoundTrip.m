/*
 * TTI-O Objective-C Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * ObjC parity for the vibrational .tio round-trip (parity-audit v1.0
 * §3.1): a run built from IR / Raman / UV-Vis spectra writes its
 * per-class metadata as run-group attributes and materializes back into
 * the right subclass. The run-attribute contract matches the Python and
 * Java writers so a vibrational .tio reads across all three languages.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Spectra/TTIOIRSpectrum.h"
#import "Spectra/TTIORamanSpectrum.h"
#import "Spectra/TTIOUVVisSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import <unistd.h>

static TTIOSignalArray *vibArr(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf length:n
                                          encoding:enc axis:nil];
}

static NSString *vibPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_vib_%d_%@.tio",
            (int)getpid(), suffix];
}

/** Write a one-spectrum run to a fresh .tio and read the first spectrum
 *  back through the on-disk reader. */
static id roundTripFirstSpectrum(TTIOAcquisitionRun *run, NSString *suffix)
{
    NSString *path = vibPath(suffix);
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
    PASS([run writeToGroup:[f rootGroup] name:@"run_0001" error:&err],
         "vibrational run writes to HDF5");
    [f close];

    TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOAcquisitionRun *back =
        [TTIOAcquisitionRun readFromGroup:[g rootGroup] name:@"run_0001" error:&err];
    PASS(back != nil, "vibrational run reads back");
    id spec = [back spectrumAtIndex:0 error:&err];
    [g close];
    unlink([path fileSystemRepresentation]);
    return spec;
}

void testJcampVibrationalRoundTrip(void)
{
    TTIOInstrumentConfig *cfg =
        [[TTIOInstrumentConfig alloc] initWithManufacturer:@"" model:@""
                                              serialNumber:@"" sourceType:@""
                                              analyzerType:@"" detectorType:@""];

    // ---- IR ----
    {
        double x[] = {400, 800, 1200, 1600, 2000, 2400};
        double y[] = {0.1, 0.5, 0.2, 0.9, 0.3, 0.7};
        NSData *xData = [NSData dataWithBytes:x length:sizeof(x)];
        NSData *yData = [NSData dataWithBytes:y length:sizeof(y)];
        NSError *e = nil;
        TTIOIRSpectrum *ir =
            [[TTIOIRSpectrum alloc] initWithWavenumberArray:vibArr(x, 6)
                                             intensityArray:vibArr(y, 6)
                                                       mode:TTIOIRModeAbsorbance
                                            resolutionCmInv:4.0
                                              numberOfScans:32
                                              indexPosition:0
                                            scanTimeSeconds:0.0
                                                      error:&e];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc] initWithSpectra:@[ir]
                                        acquisitionMode:TTIOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg];
        id spec = roundTripFirstSpectrum(run, @"ir");
        PASS([spec isKindOfClass:[TTIOIRSpectrum class]],
             "IR materializes as TTIOIRSpectrum");
        TTIOIRSpectrum *back = (TTIOIRSpectrum *)spec;
        PASS(back.mode == TTIOIRModeAbsorbance, "IR mode preserved");
        PASS(back.resolutionCmInv == 4.0, "IR resolution preserved");
        PASS(back.numberOfScans == 32, "IR scan count preserved");
        PASS([back.wavenumberArray.buffer isEqualToData:xData],
             "IR wavenumber data preserved");
        PASS([back.intensityArray.buffer isEqualToData:yData],
             "IR intensity data preserved");
    }

    // ---- Raman ----
    {
        double x[] = {200, 700, 1200, 1700, 2200, 2700};
        double y[] = {0.05, 0.4, 0.6, 0.2, 0.8, 0.1};
        NSData *xData = [NSData dataWithBytes:x length:sizeof(x)];
        NSError *e = nil;
        TTIORamanSpectrum *rm =
            [[TTIORamanSpectrum alloc] initWithWavenumberArray:vibArr(x, 6)
                                                intensityArray:vibArr(y, 6)
                                        excitationWavelengthNm:785.0
                                                  laserPowerMw:10.0
                                            integrationTimeSec:2.5
                                                 indexPosition:0
                                               scanTimeSeconds:0.0
                                                         error:&e];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc] initWithSpectra:@[rm]
                                        acquisitionMode:TTIOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg];
        id spec = roundTripFirstSpectrum(run, @"raman");
        PASS([spec isKindOfClass:[TTIORamanSpectrum class]],
             "Raman materializes as TTIORamanSpectrum");
        TTIORamanSpectrum *back = (TTIORamanSpectrum *)spec;
        PASS(back.excitationWavelengthNm == 785.0, "Raman excitation preserved");
        PASS(back.laserPowerMw == 10.0, "Raman laser power preserved");
        PASS(back.integrationTimeSec == 2.5, "Raman integration preserved");
        PASS([back.wavenumberArray.buffer isEqualToData:xData],
             "Raman wavenumber data preserved");
    }

    // ---- UV-Vis ----
    {
        double x[] = {200, 320, 440, 560, 680, 800};
        double y[] = {0.9, 0.7, 0.5, 0.3, 0.2, 0.1};
        NSData *xData = [NSData dataWithBytes:x length:sizeof(x)];
        NSError *e = nil;
        TTIOUVVisSpectrum *uv =
            [[TTIOUVVisSpectrum alloc] initWithWavelengthArray:vibArr(x, 6)
                                               absorbanceArray:vibArr(y, 6)
                                                  pathLengthCm:1.0
                                                       solvent:@"methanol"
                                                 indexPosition:0
                                               scanTimeSeconds:0.0
                                                         error:&e];
        TTIOAcquisitionRun *run =
            [[TTIOAcquisitionRun alloc] initWithSpectra:@[uv]
                                        acquisitionMode:TTIOAcquisitionModeMS1DDA
                                       instrumentConfig:cfg];
        id spec = roundTripFirstSpectrum(run, @"uvvis");
        PASS([spec isKindOfClass:[TTIOUVVisSpectrum class]],
             "UV-Vis materializes as TTIOUVVisSpectrum");
        TTIOUVVisSpectrum *back = (TTIOUVVisSpectrum *)spec;
        PASS(back.pathLengthCm == 1.0, "UV-Vis path length preserved");
        PASS([back.solvent isEqualToString:@"methanol"], "UV-Vis solvent preserved");
        PASS([back.wavelengthArray.buffer isEqualToData:xData],
             "UV-Vis wavelength data preserved");
    }
}
