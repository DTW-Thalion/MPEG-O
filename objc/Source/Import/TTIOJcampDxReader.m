/*
 * TTIOJcampDxReader.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOJcampDxReader
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Import/TTIOJcampDxReader.h
 *
 * JCAMP-DX 5.01 reader for one-dimensional vibrational and UV-Vis
 * spectra. Dispatches on ##DATA TYPE= and returns a concrete
 * TTIORamanSpectrum / TTIOIRSpectrum / TTIOUVVisSpectrum subclass;
 * delegates compressed XYDATA decoding to TTIOJcampDxDecode.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOJcampDxReader.h"
#import "TTIOJcampDxDecode.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIORamanSpectrum.h"
#import "Spectra/TTIOIRSpectrum.h"
#import "Spectra/TTIOUVVisSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOJcampDxReader

static TTIOSignalArray *makeArr(NSArray<NSNumber *> *vals)
{
    NSUInteger n = vals.count;
    double *buf = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) buf[i] = [vals[i] doubleValue];
    NSData *data = [NSData dataWithBytes:buf length:n * sizeof(double)];
    free(buf);
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:data
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static void parseLdrsAndBody(NSString *text,
                             NSMutableDictionary<NSString *, NSString *> *ldrs,
                             NSMutableArray<NSString *> *bodyLines)
{
    BOOL inXYDATA = NO;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;

        if ([line hasPrefix:@"##"]) {
            inXYDATA = NO;
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *label = [[line substringWithRange:NSMakeRange(2, eq.location - 2)]
                                stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]];
            NSString *value = [[line substringFromIndex:eq.location + 1]
                                stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]];
            ldrs[label] = value;
            if ([label isEqualToString:@"XYDATA"]) {
                inXYDATA = YES;
            } else if ([label isEqualToString:@"END"]) {
                break;
            }
            continue;
        }
        if (inXYDATA) {
            [bodyLines addObject:raw];
        }
    }
}

static BOOL parseXY(NSDictionary<NSString *, NSString *> *ldrs,
                    NSArray<NSString *> *bodyLines,
                    NSMutableArray<NSNumber *> *xs,
                    NSMutableArray<NSNumber *> *ys,
                    NSError **error)
{
    double xfactor = [ldrs[@"XFACTOR"] doubleValue];
    if (xfactor == 0.0) xfactor = 1.0;
    double yfactor = [ldrs[@"YFACTOR"] doubleValue];
    if (yfactor == 0.0) yfactor = 1.0;

    NSString *body = [bodyLines componentsJoinedByString:@"\n"];
    if ([TTIOJcampDxDecode hasCompression:body]) {
        NSString *fxs = ldrs[@"FIRSTX"];
        NSString *lxs = ldrs[@"LASTX"];
        NSString *nps = ldrs[@"NPOINTS"];
        if (!fxs || !lxs || !nps) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"JCAMP-DX: compressed XYDATA requires FIRSTX / LASTX / NPOINTS");
            return NO;
        }
        double firstx = [fxs doubleValue];
        double lastx  = [lxs doubleValue];
        NSInteger npoints = (NSInteger)[nps doubleValue];
        if (npoints < 2) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"JCAMP-DX: NPOINTS must be >= 2 for compressed data");
            return NO;
        }
        double deltax = (lastx - firstx) / (double)(npoints - 1);
        return [TTIOJcampDxDecode decodeLines:bodyLines
                                       firstx:firstx
                                       deltax:deltax
                                      xfactor:xfactor
                                      yfactor:yfactor
                                        outXs:xs
                                        outYs:ys
                                        error:error];
    }

    // AFFN fast path
    for (NSString *raw in bodyLines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        NSArray<NSString *> *toks = [line componentsSeparatedByCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray<NSNumber *> *nums = [NSMutableArray array];
        for (NSString *t in toks) {
            if (t.length == 0) continue;
            [nums addObject:@([t doubleValue])];
        }
        if (nums.count >= 2) {
            [xs addObject:@([nums[0] doubleValue] * xfactor)];
            [ys addObject:@([nums[1] doubleValue] * yfactor)];
        } else if (nums.count == 1 && xs.count == ys.count + 1) {
            [ys addObject:@([nums[0] doubleValue] * yfactor)];
        }
    }
    return YES;
}

+ (TTIOSpectrum *)readSpectrumFromPath:(NSString *)path error:(NSError **)error
{
    NSString *text = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:error];
    if (!text) return nil;

    NSMutableDictionary<NSString *, NSString *> *ldrs = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *bodyLines = [NSMutableArray array];
    parseLdrsAndBody(text, ldrs, bodyLines);

    NSMutableArray<NSNumber *> *xs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *ys = [NSMutableArray array];
    if (!parseXY(ldrs, bodyLines, xs, ys, error)) return nil;

    if (xs.count != ys.count || xs.count == 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"JCAMP-DX: empty or mismatched XYDATA");
        return nil;
    }

    NSString *dataType = [ldrs[@"DATA TYPE"] uppercaseString] ?: @"";

    if ([dataType isEqualToString:@"UV/VIS SPECTRUM"] ||
        [dataType isEqualToString:@"UV-VIS SPECTRUM"] ||
        [dataType isEqualToString:@"UV/VISIBLE SPECTRUM"]) {
        TTIOSignalArray *wlA = makeArr(xs);
        TTIOSignalArray *abA = makeArr(ys);
        double pl = [ldrs[@"$PATH LENGTH CM"] doubleValue];
        NSString *solvent = ldrs[@"$SOLVENT"] ?: @"";
        return [[TTIOUVVisSpectrum alloc] initWithWavelengthArray:wlA
                                                   absorbanceArray:abA
                                                      pathLengthCm:pl
                                                           solvent:solvent
                                                     indexPosition:0
                                                   scanTimeSeconds:0
                                                             error:error];
    }

    TTIOSignalArray *xA = makeArr(xs);
    TTIOSignalArray *yA = makeArr(ys);

    if ([dataType isEqualToString:@"RAMAN SPECTRUM"]) {
        double exc = [ldrs[@"$EXCITATION WAVELENGTH NM"] doubleValue];
        double pow = [ldrs[@"$LASER POWER MW"] doubleValue];
        double itm = [ldrs[@"$INTEGRATION TIME SEC"] doubleValue];
        return [[TTIORamanSpectrum alloc] initWithWavenumberArray:xA
                                                    intensityArray:yA
                                            excitationWavelengthNm:exc
                                                      laserPowerMw:pow
                                                integrationTimeSec:itm
                                                     indexPosition:0
                                                   scanTimeSeconds:0
                                                             error:error];
    }
    if ([dataType isEqualToString:@"INFRARED ABSORBANCE"] ||
        [dataType isEqualToString:@"INFRARED TRANSMITTANCE"] ||
        [dataType isEqualToString:@"INFRARED SPECTRUM"]) {
        TTIOIRMode mode = [dataType isEqualToString:@"INFRARED ABSORBANCE"]
            ? TTIOIRModeAbsorbance : TTIOIRModeTransmittance;
        if ([dataType isEqualToString:@"INFRARED SPECTRUM"]) {
            NSString *yU = [ldrs[@"YUNITS"] uppercaseString];
            mode = [yU containsString:@"ABSORB"] ? TTIOIRModeAbsorbance
                                                  : TTIOIRModeTransmittance;
        }
        double res    = [ldrs[@"RESOLUTION"] doubleValue];
        NSUInteger ns = (NSUInteger)[ldrs[@"$NUMBER OF SCANS"] integerValue];
        return [[TTIOIRSpectrum alloc] initWithWavenumberArray:xA
                                                 intensityArray:yA
                                                           mode:mode
                                                resolutionCmInv:res
                                                  numberOfScans:ns
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:error];
    }

    if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
        [NSString stringWithFormat:@"JCAMP-DX: unsupported DATA TYPE='%@'",
                                    ldrs[@"DATA TYPE"] ?: @""]);
    return nil;
}

@end
