/*
 * TtioNmrMLProbe — ObjC mirror of NmrMLProbe.java (and the Python
 * harness) for the cross-language nmrML parity conformance test.
 *
 * Reads an nmrML file via TTIONmrMLReader and emits the four parity
 * fields (numberOfScans, spectrometerFrequencyMHz, fidReal, fidImag)
 * as a single-line JSON object on stdout. Used by
 * python/tests/test_nmrml_cross_lang_parity.py to drive Python /
 * Java / ObjC readers against the same synthetic input and assert
 * byte-equal surface fields.
 *
 * Doubles are emitted with %.17g so the IEEE-754 round-trip is exact.
 *
 * Usage: TtioNmrMLProbe <input.nmrML>
 * Exit codes: 0 = success, 1 = argument error, 2 = read failure.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Import/TTIONmrMLReader.h"


static void appendDoubleArray(NSMutableString *out, NSString *key,
                              const double *p, NSUInteger n)
{
    [out appendString:key];
    [out appendString:@"["];
    for (NSUInteger i = 0; i < n; i++) {
        if (i > 0) [out appendString:@","];
        [out appendFormat:@"%.17g", p[i]];
    }
    [out appendString:@"]"];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: TtioNmrMLProbe <input.nmrML>\n");
            return 1;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSError *err = nil;
        TTIONmrMLReader *reader = [TTIONmrMLReader parseFilePath:path
                                                            error:&err];
        if (!reader) {
            fprintf(stderr, "nmrML read failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "(nil)");
            return 2;
        }

        NSData *re = reader.fidReal ?: [NSData data];
        NSData *im = reader.fidImag ?: [NSData data];
        const double *rp = (const double *)re.bytes;
        const double *ip = (const double *)im.bytes;
        NSUInteger n = re.length / sizeof(double);
        NSUInteger m = im.length / sizeof(double);

        NSMutableString *out = [NSMutableString stringWithCapacity:1024];
        [out appendFormat:@"{\"numberOfScans\":%lu",
            (unsigned long)reader.numberOfScans];
        [out appendFormat:@",\"spectrometerFrequencyMHz\":%.17g",
            reader.spectrometerFrequencyMHz];
        appendDoubleArray(out, @",\"fidReal\":", rp, n);
        appendDoubleArray(out, @",\"fidImag\":", ip, m);
        [out appendString:@"}"];

        const char *bytes = [out UTF8String];
        fwrite(bytes, 1, strlen(bytes), stdout);
        fputc('\n', stdout);
    }
    return 0;
}
