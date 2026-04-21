/*
 * MpgoJcampDxDump — tiny CLI driver for cross-language JCAMP-DX tests.
 *
 * Reads a JCAMP-DX file via MPGOJcampDxReader and prints
 *     x0,y0\nx1,y1\n...
 * followed by a ``CLASS=<name>:<meta>`` trailer line. Output schema
 * matches the Java M73Driver used by the Python cross-language suite
 * so both subprocess drivers can share the same parser.
 */
#import <Foundation/Foundation.h>
#import "Import/MPGOJcampDxReader.h"
#import "Spectra/MPGORamanSpectrum.h"
#import "Spectra/MPGOIRSpectrum.h"
#import "Core/MPGOSignalArray.h"
#import "ValueClasses/MPGOEnums.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <path.jdx>\n", argv[0]);
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSError *err = nil;
        MPGOSpectrum *s = [MPGOJcampDxReader readSpectrumFromPath:path error:&err];
        if (!s) {
            fprintf(stderr, "read failed: %s\n",
                    err.localizedDescription.UTF8String);
            return 1;
        }

        MPGOSignalArray *xA = nil;
        MPGOSignalArray *yA = nil;
        NSString *classTag = nil;

        if ([s isKindOfClass:[MPGORamanSpectrum class]]) {
            MPGORamanSpectrum *r = (MPGORamanSpectrum *)s;
            xA = r.wavenumberArray;
            yA = r.intensityArray;
            classTag = [NSString stringWithFormat:@"Raman:%.10g:%.10g:%.10g",
                        r.excitationWavelengthNm,
                        r.laserPowerMw,
                        r.integrationTimeSec];
        } else if ([s isKindOfClass:[MPGOIRSpectrum class]]) {
            MPGOIRSpectrum *ir = (MPGOIRSpectrum *)s;
            xA = ir.wavenumberArray;
            yA = ir.intensityArray;
            NSString *modeStr = (ir.mode == MPGOIRModeAbsorbance)
                ? @"ABSORBANCE" : @"TRANSMITTANCE";
            classTag = [NSString stringWithFormat:@"IR:%@:%.10g:%lu",
                        modeStr,
                        ir.resolutionCmInv,
                        (unsigned long)ir.numberOfScans];
        } else {
            fprintf(stderr, "unexpected spectrum class: %s\n",
                    NSStringFromClass([s class]).UTF8String);
            return 1;
        }

        NSMutableString *out = [NSMutableString string];
        const double *xs = xA.buffer.bytes;
        const double *ys = yA.buffer.bytes;
        NSUInteger n = xA.length;
        for (NSUInteger i = 0; i < n; i++) {
            [out appendFormat:@"%.17g,%.17g\n", xs[i], ys[i]];
        }
        [out appendFormat:@"CLASS=%@\n", classTag];
        fputs(out.UTF8String, stdout);
    }
    return 0;
}
