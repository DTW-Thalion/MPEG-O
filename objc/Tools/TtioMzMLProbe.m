/*
 * TtioMzMLProbe — ObjC mirror of MzMLProbe.java for the
 * cross-language mzML parity conformance test.
 *
 * Reads an mzML file via TTIOMzMLReader and emits a single-line JSON
 * object on stdout containing the per-spectrum parity surface
 * (retention time, MS level, polarity, precursor m/z + charge, full
 * mz + intensity arrays). Used by
 * python/tests/integration/test_mzml_cross_lang_parity.py.
 *
 * Doubles are emitted with %.17g so the IEEE-754 round-trip is exact
 * across languages.
 *
 * Usage: TtioMzMLProbe <input.mzML>
 * Exit codes: 0 = success, 1 = argument error, 2 = read failure.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "Import/TTIOMzMLReader.h"


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
            fprintf(stderr, "usage: TtioMzMLProbe <input.mzML>\n");
            return 1;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSError *err = nil;
        TTIOSpectralDataset *ds =
            [TTIOMzMLReader readFromFilePath:path error:&err];
        if (!ds) {
            fprintf(stderr, "mzML read failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "(nil)");
            return 2;
        }

        // Pick the first MS run (mzML produces a single run by
        // convention; the cross-lang fixtures all use one).
        NSArray *runNames = [[ds.msRuns allKeys]
            sortedArrayUsingSelector:@selector(compare:)];
        if (runNames.count == 0) {
            fprintf(stderr, "no msRuns in dataset\n");
            return 2;
        }
        TTIOAcquisitionRun *run = ds.msRuns[runNames[0]];
        TTIOSpectrumIndex *idx = run.spectrumIndex;
        NSUInteger n = idx.count;

        NSMutableString *out = [NSMutableString stringWithCapacity:4096];
        [out appendFormat:@"{\"spectrumCount\":%lu", (unsigned long)n];
        [out appendString:@",\"spectra\":["];
        for (NSUInteger i = 0; i < n; i++) {
            if (i > 0) [out appendString:@","];
            id spec = [run spectrumAtIndex:i error:&err];
            if (!spec) {
                fprintf(stderr, "spectrumAtIndex %lu failed: %s\n",
                        (unsigned long)i,
                        err ? err.localizedDescription.UTF8String : "(nil)");
                return 2;
            }
            TTIOSpectrum *s = (TTIOSpectrum *)spec;
            [out appendFormat:@"{\"retentionTime\":%.17g",
                [idx retentionTimeAt:i]];
            [out appendFormat:@",\"msLevel\":%u",
                (unsigned)[idx msLevelAt:i]];
            [out appendFormat:@",\"polarity\":%d",
                (int)[idx polarityAt:i]];
            [out appendFormat:@",\"precursorMz\":%.17g",
                [idx precursorMzAt:i]];
            [out appendFormat:@",\"precursorCharge\":%u",
                (unsigned)[idx precursorChargeAt:i]];
            TTIOSignalArray *mz = s.signalArrays[@"mz"];
            TTIOSignalArray *it = s.signalArrays[@"intensity"];
            const double *mzp = mz ? (const double *)mz.buffer.bytes : NULL;
            const double *itp = it ? (const double *)it.buffer.bytes : NULL;
            NSUInteger mzn = mz ? mz.buffer.length / sizeof(double) : 0;
            NSUInteger itn = it ? it.buffer.length / sizeof(double) : 0;
            appendDoubleArray(out, @",\"mz\":", mzp, mzn);
            appendDoubleArray(out, @",\"intensity\":", itp, itn);
            [out appendString:@"}"];
        }
        [out appendString:@"]}"];

        const char *bytes = [out UTF8String];
        fwrite(bytes, 1, strlen(bytes), stdout);
        fputc('\n', stdout);
    }
    return 0;
}
