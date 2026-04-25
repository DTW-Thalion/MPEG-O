/*
 * TtioToMzML — minimal CLI that reads an .tio file and writes the
 * first acquisition run out as an mzML document. Used by the Python
 * byte-parity harness (test_mzml_writer_parity.py) to diff the ObjC
 * writer output against Python's ttio.exporters.mzml.write_dataset
 * on the same input.
 *
 * Build with gnustep-make (see GNUmakefile).
 * Usage: TtioToMzML <path-to-.tio> <path-to-output.mzML>
 *
 * Exit codes:
 *   0  wrote output successfully
 *   1  argument error
 *   2  open/read failure
 *   3  write failure
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#import "Dataset/TTIOSpectralDataset.h"
#import "Export/TTIOMzMLWriter.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3 || argc > 4) {
            fprintf(stderr,
                "usage: %s <input.tio> <output.mzML> [--zlib]\n",
                argv[0]);
            return 1;
        }
        NSString *inputPath  = @(argv[1]);
        NSString *outputPath = @(argv[2]);
        BOOL zlib = (argc == 4 && strcmp(argv[3], "--zlib") == 0);

        NSError *error = nil;
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:inputPath error:&error];
        if (ds == nil) {
            fprintf(stderr, "open failed: %s\n",
                    error.localizedDescription.UTF8String);
            return 2;
        }

        if (![TTIOMzMLWriter writeDataset:ds
                                   toPath:outputPath
                          zlibCompression:zlib
                                    error:&error]) {
            fprintf(stderr, "write to '%s' failed: %s\n",
                    outputPath.UTF8String,
                    error.localizedDescription.UTF8String);
            [ds closeFile];
            return 3;
        }
        [ds closeFile];
        return 0;
    }
}
