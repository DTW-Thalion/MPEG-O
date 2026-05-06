/*
 * TestNmrMLReaderParity — Cross-language nmrML reader parity test.
 *
 * Mirrors the Java
 * ``ImportExportTest::nmrmlParityFieldsSurfaced`` and the Python
 * ``test_nmrml_roundtrip::test_*_round_trip`` cells: synthesises a
 * minimal nmrML with both an acquisitionParameterSet
 * (numberOfScans + irradiationFrequency) and a complex128 fidData,
 * parses it, asserts the four parity fields surface identically
 * across the three languages.
 *
 * Background: Python ``ImportResult`` gained four nmrML
 * acquisition-parameter fields on 2026-05-05 (commit fb78843);
 * Java + ObjC sibling readers were updated for parity in commit
 * f68cf81. This test pins the ObjC side of that parity contract.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Import/TTIONmrMLReader.h"
#import <unistd.h>
#import <math.h>

void testNmrMLReaderParity(void)
{
    // 32 (real, imag) pairs of float64 → 512 bytes of complex128 FID.
    NSUInteger n = 32;
    double real[n], imag[n];
    for (NSUInteger i = 0; i < n; i++) {
        real[i] = (double)i * 0.5;
        imag[i] = -(double)i * 0.25;
    }
    NSMutableData *interleaved = [NSMutableData dataWithLength:2 * n * sizeof(double)];
    double *buf = (double *)interleaved.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        buf[2 * i]     = real[i];
        buf[2 * i + 1] = imag[i];
    }
    NSString *fidB64 =
        [interleaved base64EncodedStringWithOptions:0];

    NSString *xml =
        [NSString stringWithFormat:
            @"<?xml version=\"1.0\"?>"
            "<nmrML xmlns=\"http://nmrml.org/schema\">"
            "<cvList><cv id=\"nmrCV\" fullName=\"x\" version=\"1.1.0\"/></cvList>"
            "<acquisition><acquisition1D>"
            "<acquisitionParameterSet numberOfScans=\"16\">"
            "<acquisitionNucleus name=\"1H\"/>"
            "<irradiationFrequency value=\"600000000\"/>"
            "</acquisitionParameterSet>"
            "<fidData compressed=\"false\" byteFormat=\"complex128\""
            " encodedLength=\"%lu\">%@</fidData>"
            "</acquisition1D></acquisition></nmrML>",
            (unsigned long)fidB64.length, fidB64];
    NSString *path = [NSString stringWithFormat:
        @"/tmp/ttio_test_nmrml_parity_%d.nmrML", (int)getpid()];
    [xml writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSError *err = nil;
    TTIONmrMLReader *r = [TTIONmrMLReader parseFilePath:path error:&err];
    PASS(r != nil, "nmrMLParity: reader parses synthetic file");

    // Acquisition-parameter scalars.
    PASS(r.numberOfScans == 16,
         "nmrMLParity: numberOfScans round-trips from acquisitionParameterSet attribute");
    PASS(fabs(r.spectrometerFrequencyMHz - 600.0) < 1e-9,
         "nmrMLParity: irradiationFrequency 600 MHz surfaces as MHz");

    // Deinterleaved real / imag arrays (Python ``ImportResult.fid_real``
    // / Java ``NmrMLResult.fidReal()`` parity).
    PASS(r.fidReal.length == n * sizeof(double),
         "nmrMLParity: fidReal length matches deinterleaved sample count");
    PASS(r.fidImag.length == n * sizeof(double),
         "nmrMLParity: fidImag length matches deinterleaved sample count");
    const double *re = (const double *)r.fidReal.bytes;
    const double *im = (const double *)r.fidImag.bytes;
    BOOL realOK = YES, imagOK = YES;
    for (NSUInteger i = 0; i < n; i++) {
        if (fabs(re[i] - real[i]) > 1e-12) realOK = NO;
        if (fabs(im[i] - imag[i]) > 1e-12) imagOK = NO;
    }
    PASS(realOK, "nmrMLParity: fidReal values match source");
    PASS(imagOK, "nmrMLParity: fidImag values match source");

    unlink(path.UTF8String);
}
