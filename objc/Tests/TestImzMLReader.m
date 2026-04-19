/*
 * TestImzMLReader — v0.9 M59 follow-up.
 *
 * Synthetic-fixture coverage for MPGOImzMLReader. Builds .imzML +
 * .ibd pairs in /tmp, runs them through the reader, asserts:
 *
 *   - continuous mode shares one m/z buffer across pixels
 *   - processed mode produces a distinct m/z buffer per pixel
 *   - UUID mismatch is rejected with MPGOImzMLReaderErrorUUIDMismatch
 *   - .ibd shorter than the declared offsets is rejected with
 *     MPGOImzMLReaderErrorOffsetOverflow
 *   - missing files are rejected before any parsing happens
 *
 * Cross-language equivalent:
 *   python/tests/integration/test_imzml_import.py
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Import/MPGOImzMLReader.h"

static NSString *m59ImzMLPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m59_%d_%@.imzML",
            (int)getpid(), suffix];
}

static NSString *m59IbdPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m59_%d_%@.ibd",
            (int)getpid(), suffix];
}

static void rmFile(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static NSString *uuidHexFromBytes(const unsigned char *bytes)
{
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (NSUInteger i = 0; i < 16; i++) [s appendFormat:@"%02x", bytes[i]];
    return s;
}

/**
 * Build an .imzML + .ibd pair on disk and return the bytes-on-disk size
 * via outIbdSize so callers can compute truncation thresholds.
 */
static void writeSyntheticPair(NSString *imzmlPath,
                                NSString *ibdPath,
                                NSString *mode,           // @"continuous" | @"processed"
                                NSInteger gridX,
                                NSInteger gridY,
                                NSInteger nPeaks,
                                BOOL useBadUuidInIbd,
                                NSInteger truncateIbdTo,  // -1 for no truncation
                                NSString **outIbdUUIDHex)
{
    // Deterministic UUID (32 hex chars).
    unsigned char goodUuidBytes[16] = {
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
    };
    unsigned char badUuidBytes[16] = {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    };
    NSString *goodHex = uuidHexFromBytes(goodUuidBytes);
    if (outIbdUUIDHex) *outIbdUUIDHex = goodHex;

    NSInteger nPixels = gridX * gridY;

    // Build the .ibd payload first so we know each spectrum's offsets.
    NSMutableData *payload = [NSMutableData data];
    [payload appendBytes:(useBadUuidInIbd ? badUuidBytes : goodUuidBytes) length:16];

    // For continuous mode, lay down one shared m/z block.
    NSInteger sharedMzOffset = -1;
    if ([mode isEqualToString:@"continuous"]) {
        sharedMzOffset = (NSInteger)payload.length;
        for (NSInteger i = 0; i < nPeaks; i++) {
            double v = 100.0 + (double)i;
            [payload appendBytes:&v length:sizeof(double)];
        }
    }

    NSMutableArray *mzOffsets = [NSMutableArray arrayWithCapacity:nPixels];
    NSMutableArray *intOffsets = [NSMutableArray arrayWithCapacity:nPixels];
    for (NSInteger pixel = 0; pixel < nPixels; pixel++) {
        NSInteger mzOffset;
        if ([mode isEqualToString:@"continuous"]) {
            mzOffset = sharedMzOffset;
        } else {
            mzOffset = (NSInteger)payload.length;
            for (NSInteger i = 0; i < nPeaks; i++) {
                double v = 100.0 + (double)i + (double)pixel;
                [payload appendBytes:&v length:sizeof(double)];
            }
        }
        [mzOffsets addObject:@(mzOffset)];

        NSInteger intOffset = (NSInteger)payload.length;
        [intOffsets addObject:@(intOffset)];
        for (NSInteger i = 0; i < nPeaks; i++) {
            double v = (double)pixel * 1000.0 + (double)i;
            [payload appendBytes:&v length:sizeof(double)];
        }
    }

    if (truncateIbdTo >= 0 && truncateIbdTo < (NSInteger)payload.length) {
        payload = [[payload subdataWithRange:NSMakeRange(0, (NSUInteger)truncateIbdTo)] mutableCopy];
    }
    [payload writeToFile:ibdPath atomically:YES];

    // Build the .imzML XML.
    NSString *modeAcc = [mode isEqualToString:@"continuous"] ? @"IMS:1000030" : @"IMS:1000031";
    NSMutableString *spectraXml = [NSMutableString string];
    for (NSInteger pixel = 0; pixel < nPixels; pixel++) {
        NSInteger x = (pixel % gridX) + 1;
        NSInteger y = (pixel / gridX) + 1;
        NSInteger mzOffset = [mzOffsets[pixel] integerValue];
        NSInteger intOffset = [intOffsets[pixel] integerValue];
        [spectraXml appendFormat:
            @"    <spectrum index=\"%ld\" id=\"px=%ld\">\n"
            @"      <scanList count=\"1\"><scan>\n"
            @"        <cvParam cvRef=\"IMS\" accession=\"IMS:1000050\" name=\"position x\" value=\"%ld\"/>\n"
            @"        <cvParam cvRef=\"IMS\" accession=\"IMS:1000051\" name=\"position y\" value=\"%ld\"/>\n"
            @"      </scan></scanList>\n"
            @"      <binaryDataArrayList count=\"2\">\n"
            @"        <binaryDataArray encodedLength=\"%ld\">\n"
            @"          <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
            @"          <cvParam cvRef=\"MS\" accession=\"MS:1000514\" name=\"m/z array\"/>\n"
            @"          <cvParam cvRef=\"IMS\" accession=\"IMS:1000102\" name=\"external offset\" value=\"%ld\"/>\n"
            @"          <cvParam cvRef=\"IMS\" accession=\"IMS:1000103\" name=\"external array length\" value=\"%ld\"/>\n"
            @"        </binaryDataArray>\n"
            @"        <binaryDataArray encodedLength=\"%ld\">\n"
            @"          <cvParam cvRef=\"MS\" accession=\"MS:1000523\" name=\"64-bit float\"/>\n"
            @"          <cvParam cvRef=\"MS\" accession=\"MS:1000515\" name=\"intensity array\"/>\n"
            @"          <cvParam cvRef=\"IMS\" accession=\"IMS:1000102\" name=\"external offset\" value=\"%ld\"/>\n"
            @"          <cvParam cvRef=\"IMS\" accession=\"IMS:1000103\" name=\"external array length\" value=\"%ld\"/>\n"
            @"        </binaryDataArray>\n"
            @"      </binaryDataArrayList>\n"
            @"    </spectrum>\n",
            (long)pixel, (long)pixel,
            (long)x, (long)y,
            (long)(nPeaks * 8), (long)mzOffset, (long)nPeaks,
            (long)(nPeaks * 8), (long)intOffset, (long)nPeaks];
    }

    NSString *imzml = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<mzML version=\"1.1.0\">\n"
        @"  <fileDescription><fileContent>\n"
        @"    <cvParam cvRef=\"IMS\" accession=\"IMS:1000042\" name=\"universally unique identifier\" value=\"{%@}\"/>\n"
        @"    <cvParam cvRef=\"IMS\" accession=\"%@\" name=\"%@ mode\"/>\n"
        @"  </fileContent></fileDescription>\n"
        @"  <scanSettingsList count=\"1\"><scanSettings id=\"s1\">\n"
        @"    <cvParam cvRef=\"IMS\" accession=\"IMS:1000003\" name=\"max count of pixels x\" value=\"%ld\"/>\n"
        @"    <cvParam cvRef=\"IMS\" accession=\"IMS:1000004\" name=\"max count of pixels y\" value=\"%ld\"/>\n"
        @"    <cvParam cvRef=\"IMS\" accession=\"IMS:1000040\" name=\"scan pattern\" value=\"flyback\"/>\n"
        @"  </scanSettings></scanSettingsList>\n"
        @"  <run id=\"ims_run\"><spectrumList count=\"%ld\">\n"
        @"%@"
        @"  </spectrumList></run>\n"
        @"</mzML>\n",
        goodHex, modeAcc, mode,
        (long)gridX, (long)gridY, (long)nPixels, spectraXml];
    [imzml writeToFile:imzmlPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

void testImzMLReader(void)
{
    // ── 1. Continuous mode happy path ────────────────────────────────
    {
        NSString *imzml = m59ImzMLPath(@"continuous");
        NSString *ibd   = m59IbdPath(@"continuous");
        NSString *uuidHex = nil;
        writeSyntheticPair(imzml, ibd, @"continuous", 3, 2, 8,
                            NO, -1, &uuidHex);

        NSError *err = nil;
        MPGOImzMLImport *result = [MPGOImzMLReader readFromImzMLPath:imzml
                                                              ibdPath:ibd
                                                                error:&err];
        PASS(result != nil, "continuous mode: parse succeeds");
        PASS([result.mode isEqualToString:@"continuous"], "continuous mode: mode label");
        PASS([result.uuidHex isEqualToString:uuidHex], "continuous mode: UUID matches");
        PASS(result.spectra.count == 6, "continuous mode: pixel count = 3 * 2");
        PASS(result.gridMaxX == 3 && result.gridMaxY == 2, "continuous mode: grid extents");
        // First and last pixel coords (1-indexed in IMS).
        PASS(result.spectra.firstObject.x == 1 && result.spectra.firstObject.y == 1,
             "continuous mode: first pixel (1,1)");
        PASS(result.spectra.lastObject.x == 3 && result.spectra.lastObject.y == 2,
             "continuous mode: last pixel (3,2)");
        // Continuous contract: every pixel aliases the same m/z buffer.
        BOOL allShared = YES;
        for (MPGOImzMLPixelSpectrum *s in result.spectra) {
            if (s.mzArray != result.spectra.firstObject.mzArray) { allShared = NO; break; }
        }
        PASS(allShared, "continuous mode: pixels share the m/z NSData object");

        rmFile(imzml); rmFile(ibd);
    }

    // ── 2. Processed mode — distinct m/z per pixel ───────────────────
    {
        NSString *imzml = m59ImzMLPath(@"processed");
        NSString *ibd   = m59IbdPath(@"processed");
        NSString *uuidHex = nil;
        writeSyntheticPair(imzml, ibd, @"processed", 2, 3, 4,
                            NO, -1, &uuidHex);

        NSError *err = nil;
        MPGOImzMLImport *result = [MPGOImzMLReader readFromImzMLPath:imzml
                                                              ibdPath:ibd
                                                                error:&err];
        PASS(result != nil, "processed mode: parse succeeds");
        PASS([result.mode isEqualToString:@"processed"], "processed mode: mode label");
        PASS(result.spectra.count == 6, "processed mode: pixel count = 2 * 3");
        // Different pixels must point at different m/z buffers (no aliasing).
        PASS(result.spectra[0].mzArray != result.spectra[1].mzArray,
             "processed mode: per-pixel m/z buffers are distinct");
        // Sanity: first peak of pixel 1 m/z block = 100 + offset(0,1,...) per build rule.
        const double *mz0 = result.spectra[0].mzArray.bytes;
        PASS(mz0[0] == 100.0, "processed mode: pixel 0 m/z[0] = 100.0");
        const double *mz1 = result.spectra[1].mzArray.bytes;
        PASS(mz1[0] == 101.0, "processed mode: pixel 1 m/z[0] = 101.0");

        rmFile(imzml); rmFile(ibd);
    }

    // ── 3. UUID mismatch → ImzMLReaderErrorUUIDMismatch ──────────────
    {
        NSString *imzml = m59ImzMLPath(@"uuidbad");
        NSString *ibd   = m59IbdPath(@"uuidbad");
        NSString *uuidHex = nil;
        writeSyntheticPair(imzml, ibd, @"continuous", 1, 1, 4,
                            YES /*bad UUID*/, -1, &uuidHex);

        NSError *err = nil;
        MPGOImzMLImport *result = [MPGOImzMLReader readFromImzMLPath:imzml
                                                              ibdPath:ibd
                                                                error:&err];
        PASS(result == nil, "UUID mismatch: returns nil");
        PASS(err != nil && err.code == MPGOImzMLReaderErrorUUIDMismatch,
             "UUID mismatch: error code MPGOImzMLReaderErrorUUIDMismatch");

        rmFile(imzml); rmFile(ibd);
    }

    // ── 4. Truncated .ibd → MPGOImzMLReaderErrorOffsetOverflow ───────
    {
        NSString *imzml = m59ImzMLPath(@"truncate");
        NSString *ibd   = m59IbdPath(@"truncate");
        NSString *uuidHex = nil;
        writeSyntheticPair(imzml, ibd, @"continuous", 1, 1, 8,
                            NO, 20 /*keep UUID, kill payload*/, &uuidHex);

        NSError *err = nil;
        MPGOImzMLImport *result = [MPGOImzMLReader readFromImzMLPath:imzml
                                                              ibdPath:ibd
                                                                error:&err];
        PASS(result == nil, "truncated .ibd: returns nil");
        PASS(err != nil && err.code == MPGOImzMLReaderErrorOffsetOverflow,
             "truncated .ibd: error code MPGOImzMLReaderErrorOffsetOverflow");

        rmFile(imzml); rmFile(ibd);
    }

    // ── 5. Missing files ─────────────────────────────────────────────
    {
        NSError *err = nil;
        MPGOImzMLImport *result = [MPGOImzMLReader readFromImzMLPath:@"/tmp/__no_such__.imzML"
                                                              ibdPath:nil
                                                                error:&err];
        PASS(result == nil, "missing imzML: returns nil");
        PASS(err != nil && err.code == MPGOImzMLReaderErrorMissingFile,
             "missing imzML: error code MissingFile");
    }
}
