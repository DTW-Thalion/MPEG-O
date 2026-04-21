#import "MPGOJcampDxWriter.h"
#import "Spectra/MPGORamanSpectrum.h"
#import "Spectra/MPGOIRSpectrum.h"
#import "Spectra/MPGOUVVisSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOJcampDxWriter

static void appendXYDATA(NSMutableString *out,
                         const double *xs, const double *ys, NSUInteger n)
{
    // ##XYDATA=(X++(Y..Y)) AFFN: each line is X followed by the Y value
    // at that X. For our minimal dialect we emit one (X, Y) pair per
    // line; this is valid AFFN and trivially parseable back.
    [out appendString:@"##XYDATA=(X++(Y..Y))\n"];
    for (NSUInteger i = 0; i < n; i++) {
        [out appendFormat:@"%.10g %.10g\n", xs[i], ys[i]];
    }
}

static NSArray<NSNumber *> *float64Values(MPGOSignalArray *arr)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:arr.length];
    const double *p = arr.buffer.bytes;
    for (NSUInteger i = 0; i < arr.length; i++) {
        [out addObject:@(p[i])];
    }
    return out;
}

static BOOL writeStringToPath(NSString *s, NSString *path, NSError **error)
{
    return [s writeToFile:path
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:error];
}

+ (BOOL)writeRamanSpectrum:(MPGORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error
{
    if (!spec || spec.wavenumberArray.length != spec.intensityArray.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOJcampDxWriter: invalid Raman spectrum");
        return NO;
    }

    NSUInteger n = spec.wavenumberArray.length;
    const double *xs = spec.wavenumberArray.buffer.bytes;
    const double *ys = spec.intensityArray.buffer.bytes;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"##TITLE=%@\n", title ?: @""];
    [out appendString:@"##JCAMP-DX=5.01\n"];
    [out appendString:@"##DATA TYPE=RAMAN SPECTRUM\n"];
    [out appendString:@"##ORIGIN=MPEG-O\n"];
    [out appendString:@"##OWNER=\n"];
    [out appendString:@"##XUNITS=1/CM\n"];
    [out appendString:@"##YUNITS=ARBITRARY UNITS\n"];
    [out appendFormat:@"##FIRSTX=%.10g\n", n > 0 ? xs[0] : 0.0];
    [out appendFormat:@"##LASTX=%.10g\n",  n > 0 ? xs[n-1] : 0.0];
    [out appendFormat:@"##NPOINTS=%lu\n", (unsigned long)n];
    [out appendString:@"##XFACTOR=1\n"];
    [out appendString:@"##YFACTOR=1\n"];
    [out appendFormat:@"##$EXCITATION WAVELENGTH NM=%.10g\n", spec.excitationWavelengthNm];
    [out appendFormat:@"##$LASER POWER MW=%.10g\n",          spec.laserPowerMw];
    [out appendFormat:@"##$INTEGRATION TIME SEC=%.10g\n",    spec.integrationTimeSec];
    appendXYDATA(out, xs, ys, n);
    [out appendString:@"##END=\n"];

    return writeStringToPath(out, path, error);
}

+ (BOOL)writeIRSpectrum:(MPGOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
                  error:(NSError **)error
{
    if (!spec || spec.wavenumberArray.length != spec.intensityArray.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOJcampDxWriter: invalid IR spectrum");
        return NO;
    }

    NSUInteger n = spec.wavenumberArray.length;
    const double *xs = spec.wavenumberArray.buffer.bytes;
    const double *ys = spec.intensityArray.buffer.bytes;

    NSString *dataType = (spec.mode == MPGOIRModeAbsorbance)
        ? @"INFRARED ABSORBANCE" : @"INFRARED TRANSMITTANCE";
    NSString *yUnits = (spec.mode == MPGOIRModeAbsorbance)
        ? @"ABSORBANCE" : @"TRANSMITTANCE";

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"##TITLE=%@\n", title ?: @""];
    [out appendString:@"##JCAMP-DX=5.01\n"];
    [out appendFormat:@"##DATA TYPE=%@\n", dataType];
    [out appendString:@"##ORIGIN=MPEG-O\n"];
    [out appendString:@"##OWNER=\n"];
    [out appendString:@"##XUNITS=1/CM\n"];
    [out appendFormat:@"##YUNITS=%@\n", yUnits];
    [out appendFormat:@"##FIRSTX=%.10g\n", n > 0 ? xs[0] : 0.0];
    [out appendFormat:@"##LASTX=%.10g\n",  n > 0 ? xs[n-1] : 0.0];
    [out appendFormat:@"##NPOINTS=%lu\n", (unsigned long)n];
    [out appendString:@"##XFACTOR=1\n"];
    [out appendString:@"##YFACTOR=1\n"];
    [out appendFormat:@"##RESOLUTION=%.10g\n", spec.resolutionCmInv];
    [out appendFormat:@"##$NUMBER OF SCANS=%lu\n", (unsigned long)spec.numberOfScans];
    appendXYDATA(out, xs, ys, n);
    [out appendString:@"##END=\n"];

    return writeStringToPath(out, path, error);
}

+ (BOOL)writeUVVisSpectrum:(MPGOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error
{
    if (!spec || spec.wavelengthArray.length != spec.absorbanceArray.length) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"MPGOJcampDxWriter: invalid UV-Vis spectrum");
        return NO;
    }

    NSUInteger n = spec.wavelengthArray.length;
    const double *xs = spec.wavelengthArray.buffer.bytes;
    const double *ys = spec.absorbanceArray.buffer.bytes;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"##TITLE=%@\n", title ?: @""];
    [out appendString:@"##JCAMP-DX=5.01\n"];
    [out appendString:@"##DATA TYPE=UV/VIS SPECTRUM\n"];
    [out appendString:@"##ORIGIN=MPEG-O\n"];
    [out appendString:@"##OWNER=\n"];
    [out appendString:@"##XUNITS=NANOMETERS\n"];
    [out appendString:@"##YUNITS=ABSORBANCE\n"];
    [out appendFormat:@"##FIRSTX=%.10g\n", n > 0 ? xs[0] : 0.0];
    [out appendFormat:@"##LASTX=%.10g\n",  n > 0 ? xs[n-1] : 0.0];
    [out appendFormat:@"##NPOINTS=%lu\n", (unsigned long)n];
    [out appendString:@"##XFACTOR=1\n"];
    [out appendString:@"##YFACTOR=1\n"];
    [out appendFormat:@"##$PATH LENGTH CM=%.10g\n", spec.pathLengthCm];
    [out appendFormat:@"##$SOLVENT=%@\n",           spec.solvent ?: @""];
    appendXYDATA(out, xs, ys, n);
    [out appendString:@"##END=\n"];

    return writeStringToPath(out, path, error);
}

@end
