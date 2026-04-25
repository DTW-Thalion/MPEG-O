/*
 * TtioJcampDxDump — tiny CLI driver for cross-language JCAMP-DX tests.
 *
 * Reads a JCAMP-DX file via TTIOJcampDxReader and prints
 *     x0,y0\nx1,y1\n...
 * followed by a ``CLASS=<name>:<meta>`` trailer line. Output schema
 * matches the Java M73Driver used by the Python cross-language suite
 * so both subprocess drivers can share the same parser.
 */
#import <Foundation/Foundation.h>
#import "Import/TTIOJcampDxReader.h"
#import "Spectra/TTIORamanSpectrum.h"
#import "Spectra/TTIOIRSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEnums.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <path.jdx>\n", argv[0]);
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSError *err = nil;
        TTIOSpectrum *s = [TTIOJcampDxReader readSpectrumFromPath:path error:&err];
        if (!s) {
            fprintf(stderr, "read failed: %s\n",
                    err.localizedDescription.UTF8String);
            return 1;
        }

        TTIOSignalArray *xA = nil;
        TTIOSignalArray *yA = nil;
        NSString *classTag = nil;

        if ([s isKindOfClass:[TTIORamanSpectrum class]]) {
            TTIORamanSpectrum *r = (TTIORamanSpectrum *)s;
            xA = r.wavenumberArray;
            yA = r.intensityArray;
            classTag = [NSString stringWithFormat:@"Raman:%.10g:%.10g:%.10g",
                        r.excitationWavelengthNm,
                        r.laserPowerMw,
                        r.integrationTimeSec];
        } else if ([s isKindOfClass:[TTIOIRSpectrum class]]) {
            TTIOIRSpectrum *ir = (TTIOIRSpectrum *)s;
            xA = ir.wavenumberArray;
            yA = ir.intensityArray;
            NSString *modeStr = (ir.mode == TTIOIRModeAbsorbance)
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
