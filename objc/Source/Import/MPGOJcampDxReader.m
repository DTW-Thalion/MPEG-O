#import "MPGOJcampDxReader.h"
#import "Spectra/MPGOSpectrum.h"
#import "Spectra/MPGORamanSpectrum.h"
#import "Spectra/MPGOIRSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOJcampDxReader

static MPGOSignalArray *makeArr(NSArray<NSNumber *> *vals)
{
    NSUInteger n = vals.count;
    double *buf = malloc(n * sizeof(double));
    for (NSUInteger i = 0; i < n; i++) buf[i] = [vals[i] doubleValue];
    NSData *data = [NSData dataWithBytes:buf length:n * sizeof(double)];
    free(buf);
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:data
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

+ (MPGOSpectrum *)readSpectrumFromPath:(NSString *)path error:(NSError **)error
{
    NSString *text = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:error];
    if (!text) return nil;

    NSMutableDictionary<NSString *, NSString *> *ldrs = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *xs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *ys = [NSMutableArray array];
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
            NSArray<NSString *> *toks = [line componentsSeparatedByCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray<NSNumber *> *nums = [NSMutableArray array];
            for (NSString *t in toks) {
                if (t.length == 0) continue;
                [nums addObject:@([t doubleValue])];
            }
            if (nums.count >= 2) {
                [xs addObject:nums[0]];
                [ys addObject:nums[1]];
            } else if (nums.count == 1 && xs.count == ys.count + 1) {
                [ys addObject:nums[0]];
            }
        }
    }

    NSString *dataType = [ldrs[@"DATA TYPE"] uppercaseString] ?: @"";
    if (xs.count != ys.count || xs.count == 0) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"JCAMP-DX: empty or mismatched XYDATA");
        return nil;
    }

    MPGOSignalArray *xA = makeArr(xs);
    MPGOSignalArray *yA = makeArr(ys);

    if ([dataType isEqualToString:@"RAMAN SPECTRUM"]) {
        double exc = [ldrs[@"$EXCITATION WAVELENGTH NM"] doubleValue];
        double pow = [ldrs[@"$LASER POWER MW"] doubleValue];
        double itm = [ldrs[@"$INTEGRATION TIME SEC"] doubleValue];
        return [[MPGORamanSpectrum alloc] initWithWavenumberArray:xA
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
        MPGOIRMode mode = [dataType isEqualToString:@"INFRARED ABSORBANCE"]
            ? MPGOIRModeAbsorbance : MPGOIRModeTransmittance;
        // Fall back on YUNITS if DATA TYPE is the generic "INFRARED SPECTRUM"
        if ([dataType isEqualToString:@"INFRARED SPECTRUM"]) {
            NSString *yU = [ldrs[@"YUNITS"] uppercaseString];
            mode = [yU containsString:@"ABSORB"] ? MPGOIRModeAbsorbance
                                                  : MPGOIRModeTransmittance;
        }
        double res    = [ldrs[@"RESOLUTION"] doubleValue];
        NSUInteger ns = (NSUInteger)[ldrs[@"$NUMBER OF SCANS"] integerValue];
        return [[MPGOIRSpectrum alloc] initWithWavenumberArray:xA
                                                 intensityArray:yA
                                                           mode:mode
                                                resolutionCmInv:res
                                                  numberOfScans:ns
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:error];
    }

    if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
        [NSString stringWithFormat:@"JCAMP-DX: unsupported DATA TYPE='%@'",
                                    ldrs[@"DATA TYPE"] ?: @""]);
    return nil;
}

@end
