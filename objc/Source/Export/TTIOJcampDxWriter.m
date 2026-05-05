/*
 * TTIOJcampDxWriter.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOJcampDxWriter
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Export/TTIOJcampDxWriter.h
 *
 * JCAMP-DX 5.01 writer for one-dimensional vibrational spectra
 * (Raman / IR / UV-Vis). Emits AFFN by default; PAC / SQZ / DIF
 * compressed encodings are routed through TTIOJcampDxEncode.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOJcampDxWriter.h"
#import "TTIOJcampDxEncode.h"
#import "Spectra/TTIORamanSpectrum.h"
#import "Spectra/TTIOIRSpectrum.h"
#import "Spectra/TTIOUVVisSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <math.h>

@implementation TTIOJcampDxWriter

// ── Shared helpers ─────────────────────────────────────────────

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

static BOOL writeStringToPath(NSString *s, NSString *path, NSError **error)
{
    return [s writeToFile:path
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:error];
}

static BOOL verifyEquispaced(const double *xs, NSUInteger n,
                              double firstx, double deltax,
                              NSError **error)
{
    double maxAbs = 0.0;
    for (NSUInteger i = 0; i < n; i++) {
        double expected = firstx + (double)i * deltax;
        double a = fabs(expected);
        if (a > maxAbs) maxAbs = a;
    }
    double tol = 1e-9 * maxAbs;
    if (tol < 1e-9) tol = 1e-9;
    for (NSUInteger i = 0; i < n; i++) {
        double expected = firstx + (double)i * deltax;
        if (fabs(xs[i] - expected) > tol) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"TTIOJcampDxWriter: compressed encoding requires equispaced X");
            return NO;
        }
    }
    return YES;
}

static NSString *buildCompressedDocument(const double *xs, const double *ys, NSUInteger n,
                                          TTIOJcampDxEncoding mode,
                                          NSString *title,
                                          NSString *dataType,
                                          NSString *xUnits,
                                          NSString *yUnits,
                                          NSArray<NSString *> *tailLdrs,
                                          NSError **error)
{
    if (n < 2) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOJcampDxWriter: compressed encoding requires NPOINTS >= 2");
        return nil;
    }
    double firstx = xs[0];
    double deltax = (xs[n - 1] - xs[0]) / (double)(n - 1);
    if (!verifyEquispaced(xs, n, firstx, deltax, error)) {
        return nil;
    }

    double yfactor = TTIOJcampChooseYFactor(ys, n, 7);
    NSString *body = TTIOJcampEncodeXYData(ys, n, firstx, deltax, yfactor, mode);

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"##TITLE=%@\n", title ?: @""];
    [out appendString:@"##JCAMP-DX=5.01\n"];
    [out appendFormat:@"##DATA TYPE=%@\n", dataType];
    [out appendString:@"##ORIGIN=TTI-O\n"];
    [out appendString:@"##OWNER=\n"];
    [out appendFormat:@"##XUNITS=%@\n", xUnits];
    [out appendFormat:@"##YUNITS=%@\n", yUnits];
    [out appendFormat:@"##FIRSTX=%@\n", TTIOJcampFormatG10(xs[0])];
    [out appendFormat:@"##LASTX=%@\n",  TTIOJcampFormatG10(xs[n - 1])];
    [out appendFormat:@"##NPOINTS=%lu\n", (unsigned long)n];
    [out appendString:@"##XFACTOR=1\n"];
    [out appendFormat:@"##YFACTOR=%@\n", TTIOJcampFormatG10(yfactor)];
    for (NSString *ldr in tailLdrs) {
        [out appendFormat:@"%@\n", ldr];
    }
    [out appendString:@"##XYDATA=(X++(Y..Y))\n"];
    [out appendString:body];
    [out appendString:@"##END=\n"];
    return out;
}

// ── AFFN (existing M73 path) ───────────────────────────────────

+ (BOOL)writeRamanSpectrum:(TTIORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error
{
    return [self writeRamanSpectrum:spec
                             toPath:path
                              title:title
                           encoding:TTIOJcampDxEncodingAFFN
                              error:error];
}

+ (BOOL)writeIRSpectrum:(TTIOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
                  error:(NSError **)error
{
    return [self writeIRSpectrum:spec
                          toPath:path
                           title:title
                        encoding:TTIOJcampDxEncodingAFFN
                           error:error];
}

+ (BOOL)writeUVVisSpectrum:(TTIOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                     error:(NSError **)error
{
    return [self writeUVVisSpectrum:spec
                             toPath:path
                              title:title
                           encoding:TTIOJcampDxEncodingAFFN
                              error:error];
}

// ── AFFN + compressed dispatch (M76) ───────────────────────────

+ (BOOL)writeRamanSpectrum:(TTIORamanSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(TTIOJcampDxEncoding)encoding
                     error:(NSError **)error
{
    if (!spec || spec.wavenumberArray.length != spec.intensityArray.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOJcampDxWriter: invalid Raman spectrum");
        return NO;
    }

    NSUInteger n = spec.wavenumberArray.length;
    const double *xs = spec.wavenumberArray.buffer.bytes;
    const double *ys = spec.intensityArray.buffer.bytes;

    if (encoding == TTIOJcampDxEncodingAFFN) {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"##TITLE=%@\n", title ?: @""];
        [out appendString:@"##JCAMP-DX=5.01\n"];
        [out appendString:@"##DATA TYPE=RAMAN SPECTRUM\n"];
        [out appendString:@"##ORIGIN=TTI-O\n"];
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

    NSArray<NSString *> *tail = @[
        [NSString stringWithFormat:@"##$EXCITATION WAVELENGTH NM=%@",
                TTIOJcampFormatG10(spec.excitationWavelengthNm)],
        [NSString stringWithFormat:@"##$LASER POWER MW=%@",
                TTIOJcampFormatG10(spec.laserPowerMw)],
        [NSString stringWithFormat:@"##$INTEGRATION TIME SEC=%@",
                TTIOJcampFormatG10(spec.integrationTimeSec)],
    ];
    NSString *doc = buildCompressedDocument(xs, ys, n, encoding,
            title, @"RAMAN SPECTRUM", @"1/CM", @"ARBITRARY UNITS",
            tail, error);
    if (!doc) return NO;
    return writeStringToPath(doc, path, error);
}

+ (BOOL)writeIRSpectrum:(TTIOIRSpectrum *)spec
                 toPath:(NSString *)path
                  title:(NSString *)title
               encoding:(TTIOJcampDxEncoding)encoding
                  error:(NSError **)error
{
    if (!spec || spec.wavenumberArray.length != spec.intensityArray.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOJcampDxWriter: invalid IR spectrum");
        return NO;
    }

    NSUInteger n = spec.wavenumberArray.length;
    const double *xs = spec.wavenumberArray.buffer.bytes;
    const double *ys = spec.intensityArray.buffer.bytes;

    NSString *dataType = (spec.mode == TTIOIRModeAbsorbance)
        ? @"INFRARED ABSORBANCE" : @"INFRARED TRANSMITTANCE";
    NSString *yUnits = (spec.mode == TTIOIRModeAbsorbance)
        ? @"ABSORBANCE" : @"TRANSMITTANCE";

    if (encoding == TTIOJcampDxEncodingAFFN) {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"##TITLE=%@\n", title ?: @""];
        [out appendString:@"##JCAMP-DX=5.01\n"];
        [out appendFormat:@"##DATA TYPE=%@\n", dataType];
        [out appendString:@"##ORIGIN=TTI-O\n"];
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

    NSArray<NSString *> *tail = @[
        [NSString stringWithFormat:@"##RESOLUTION=%@",
                TTIOJcampFormatG10(spec.resolutionCmInv)],
        [NSString stringWithFormat:@"##$NUMBER OF SCANS=%lu",
                (unsigned long)spec.numberOfScans],
    ];
    NSString *doc = buildCompressedDocument(xs, ys, n, encoding,
            title, dataType, @"1/CM", yUnits, tail, error);
    if (!doc) return NO;
    return writeStringToPath(doc, path, error);
}

+ (BOOL)writeUVVisSpectrum:(TTIOUVVisSpectrum *)spec
                    toPath:(NSString *)path
                     title:(NSString *)title
                  encoding:(TTIOJcampDxEncoding)encoding
                     error:(NSError **)error
{
    if (!spec || spec.wavelengthArray.length != spec.absorbanceArray.length) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"TTIOJcampDxWriter: invalid UV-Vis spectrum");
        return NO;
    }

    NSUInteger n = spec.wavelengthArray.length;
    const double *xs = spec.wavelengthArray.buffer.bytes;
    const double *ys = spec.absorbanceArray.buffer.bytes;

    if (encoding == TTIOJcampDxEncodingAFFN) {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"##TITLE=%@\n", title ?: @""];
        [out appendString:@"##JCAMP-DX=5.01\n"];
        [out appendString:@"##DATA TYPE=UV/VIS SPECTRUM\n"];
        [out appendString:@"##ORIGIN=TTI-O\n"];
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

    NSArray<NSString *> *tail = @[
        [NSString stringWithFormat:@"##$PATH LENGTH CM=%@",
                TTIOJcampFormatG10(spec.pathLengthCm)],
        [NSString stringWithFormat:@"##$SOLVENT=%@", spec.solvent ?: @""],
    ];
    NSString *doc = buildCompressedDocument(xs, ys, n, encoding,
            title, @"UV/VIS SPECTRUM", @"NANOMETERS", @"ABSORBANCE",
            tail, error);
    if (!doc) return NO;
    return writeStringToPath(doc, path, error);
}

@end
