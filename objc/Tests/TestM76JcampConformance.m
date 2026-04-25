#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "Spectra/TTIOUVVisSpectrum.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "Export/TTIOJcampDxWriter.h"
#import "Export/TTIOJcampDxEncoding.h"
#import <unistd.h>

// M76 byte-parity conformance test for the ObjC JCAMP-DX compressed
// writer. Each mode (PAC / SQZ / DIF) has a matching golden fixture
// under conformance/jcamp_dx/. Python and Java ship the analogous
// tests — together they form the M76 cross-language byte-parity gate.

static NSString *conformanceDir(void)
{
    // objc/Tests runs from the build/test dir. Walk upward looking
    // for conformance/jcamp_dx so the test works from any sane CWD.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *here = [fm currentDirectoryPath];
    for (int up = 0; up < 6; up++) {
        NSString *candidate = [[here
                stringByAppendingPathComponent:@"conformance"]
                stringByAppendingPathComponent:@"jcamp_dx"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            return candidate;
        }
        here = [here stringByDeletingLastPathComponent];
        if ([here isEqualToString:@"/"] || here.length == 0) break;
    }
    return nil;
}

static TTIOSignalArray *float64Arr(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static TTIOUVVisSpectrum *ramp25Fixture(void)
{
    const NSUInteger N = 25;
    double *wl     = malloc(N * sizeof(double));
    double *absorb = malloc(N * sizeof(double));
    for (NSUInteger i = 0; i < N; i++) {
        wl[i]     = 200.0 + (double)i * 10.0;
        double a  = (double)i;
        double b  = 24.0 - (double)i;
        absorb[i] = (a < b) ? a : b;
    }
    TTIOSignalArray *wlA = float64Arr(wl, N);
    TTIOSignalArray *abA = float64Arr(absorb, N);
    free(wl); free(absorb);
    NSError *initErr = nil;
    TTIOUVVisSpectrum *spec = [[TTIOUVVisSpectrum alloc]
            initWithWavelengthArray:wlA
                    absorbanceArray:abA
                       pathLengthCm:1.0
                            solvent:@"water"
                      indexPosition:0
                    scanTimeSeconds:0.0
                              error:&initErr];
    if (!spec) {
        NSLog(@"UVVisSpectrum init failed: %@", initErr);
    }
    return spec;
}

static void checkOneMode(TTIOJcampDxEncoding mode,
                          NSString *modeName,
                          NSString *fixtureFile,
                          NSString *confDir)
{
    NSString *golden = [confDir stringByAppendingPathComponent:fixtureFile];
    if (![[NSFileManager defaultManager] fileExistsAtPath:golden]) {
        // Golden missing — treat as skip (Python + Java gate is the
        // first line of defense, we don't want the ObjC suite to fail
        // hard when fixtures are absent from a partial checkout).
        pass(YES, "skip: fixture missing %s", [golden UTF8String]);
        return;
    }
    NSString *outPath = [NSString stringWithFormat:@"/tmp/ttio_m76_%d_%@.jdx",
                         (int)getpid(), modeName];

    NSError *err = nil;
    BOOL ok = [TTIOJcampDxWriter writeUVVisSpectrum:ramp25Fixture()
                                              toPath:outPath
                                               title:@"m76 ramp-25"
                                            encoding:mode
                                               error:&err];
    pass(ok, "write %s: %s", [modeName UTF8String],
         err ? [[err localizedDescription] UTF8String] : "ok");

    NSData *produced = [NSData dataWithContentsOfFile:outPath];
    NSData *expected = [NSData dataWithContentsOfFile:golden];
    BOOL match = [produced isEqualToData:expected];
    if (!match) {
        NSString *producedStr = [[NSString alloc] initWithData:produced
                                                      encoding:NSUTF8StringEncoding];
        NSString *expectedStr = [[NSString alloc] initWithData:expected
                                                      encoding:NSUTF8StringEncoding];
        NSLog(@"byte-parity drift on %@ encoder.\n--- expected ---\n%@--- produced ---\n%@",
              modeName, expectedStr, producedStr);
    }
    pass(match, "byte-parity %s", [modeName UTF8String]);

    unlink([outPath fileSystemRepresentation]);
}

void testM76JcampConformance(void)
{
    NSString *confDir = conformanceDir();
    if (!confDir) {
        pass(YES, "skip: conformance/jcamp_dx not reachable from CWD");
        return;
    }
    checkOneMode(TTIOJcampDxEncodingPAC, @"pac", @"uvvis_ramp25_pac.jdx", confDir);
    checkOneMode(TTIOJcampDxEncodingSQZ, @"sqz", @"uvvis_ramp25_sqz.jdx", confDir);
    checkOneMode(TTIOJcampDxEncodingDIF, @"dif", @"uvvis_ramp25_dif.jdx", confDir);
}
