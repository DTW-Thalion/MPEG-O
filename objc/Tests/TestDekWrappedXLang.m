/*
 * TestDekWrappedXLang — cross-language dek_wrapped envelope-encryption
 * conformance.
 *
 * Proves that the dataset-level wrapped-DEK blob at
 * /protection/key_info/dek_wrapped written by ANY language (Python /
 * Java / ObjC) is correctly read AND unwrapped by ObjC. Combined with
 * the Python (test_dek_wrapped_xlang.py) and Java (DekWrappedXLangTest)
 * peers, this gives the full NxN writer×reader matrix.
 *
 * This is the conformance test whose ABSENCE let the
 * fix/dek-wrapped-xlang bug ship: Java/ObjC used to store dek_wrapped
 * as an int32-packed, 4-byte-padded dataset while Python stored the
 * spec-compliant uint8[N] exact-length blob, so a file written by one
 * language crashed / corrupted (1639→60 truncation) when read by
 * another. All three now write uint8[N].
 *
 * Fixtures + committed KEK + expected DEK hex live under
 * conformance/key_rotation/ and are produced by
 * conformance/key_rotation/gen_fixtures.py.
 *
 * Coverage: AES-256-GCM (71-byte) across py/java/objc writers, plus
 * ML-KEM-1024 (1639-byte) across py/objc writers when liboqs is
 * available (skipped otherwise).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "Protection/TTIOKeyRotationManager.h"
#import "Protection/TTIOPostQuantumCrypto.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *dekHex(NSData *d) {
    const uint8_t *b = d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

/** Walk up from the cwd to locate the conformance key_rotation dir. */
static NSString *conformanceDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [fm currentDirectoryPath];
    for (int i = 0; i < 6 && dir.length; i++) {
        NSString *cand = [dir stringByAppendingPathComponent:
                          @"conformance/key_rotation/expected.json"];
        if ([fm fileExistsAtPath:cand]) {
            return [dir stringByAppendingPathComponent:@"conformance/key_rotation"];
        }
        dir = [dir stringByDeletingLastPathComponent];
    }
    return nil;
}

void testDekWrappedXLang(void)
{
    NSString *dir = conformanceDir();
    PASS(dir != nil, "conformance/key_rotation fixtures located");
    if (!dir) return;

    NSData *manifestRaw = [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent:@"expected.json"]];
    NSError *jerr = nil;
    NSDictionary *doc = [NSJSONSerialization JSONObjectWithData:manifestRaw
                                                        options:0 error:&jerr];
    PASS([doc isKindOfClass:[NSDictionary class]], "expected.json parsed");
    if (![doc isKindOfClass:[NSDictionary class]]) return;

    NSData *aesKek = [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent:@"kek_aes.bin"]];
    PASS(aesKek.length == 32, "AES KEK is 32 bytes");

    NSData *mlkemPriv = [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent:@"kek_mlkem_priv.bin"]];
    BOOL pqc = [TTIOPostQuantumCrypto isAvailable] && mlkemPriv.length == 3168;

    NSArray<NSDictionary *> *fixtures = doc[@"fixtures"];
    PASS(fixtures.count >= 3, "at least the three AES writers present");

    NSString *fixDir = [dir stringByAppendingPathComponent:@"fixtures"];
    BOOL sawPythonAes = NO;

    for (NSDictionary *fx in fixtures) {
        NSString *name = fx[@"fixture"];
        NSString *algorithm = fx[@"algorithm"];
        NSString *writer = fx[@"writer"];
        NSString *expected = fx[@"expected_dek_hex"];
        BOOL isAes = [algorithm isEqualToString:@"aes-256-gcm"];

        if (!isAes && !pqc) {
            // liboqs/ML-KEM unavailable — skip PQC fixtures gracefully.
            continue;
        }

        NSString *tio = [fixDir stringByAppendingPathComponent:name];
        NSError *err = nil;

        // Guard the on-disk layout: the bug was a non-uint8 dataset.
        TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:tio error:&err];
        PASS(f != nil, "%s: opened", name.UTF8String);
        if (!f) continue;
        TTIOHDF5Group *root = [f rootGroup];
        TTIOHDF5Group *prot = [root openGroupNamed:@"protection" error:&err];
        TTIOHDF5Group *ki = [prot openGroupNamed:@"key_info" error:&err];
        TTIOHDF5Dataset *ds = [ki openDatasetNamed:@"dek_wrapped" error:&err];
        PASS(ds != nil && ds.precision == TTIOPrecisionUInt8,
             "%s: dek_wrapped is uint8 (int32 layout corrupts cross-lang)",
             name.UTF8String);
        NSUInteger wantLen = isAes ? 71 : 1639;
        PASS(ds != nil && ds.length == wantLen,
             "%s: dek_wrapped is exactly %lu bytes (unpadded)",
             name.UTF8String, (unsigned long)wantLen);

        // Unwrap via the public read path and assert the recovered DEK.
        TTIOKeyRotationManager *mgr = [TTIOKeyRotationManager managerWithFile:f];
        NSData *dek = nil;
        if (isAes) {
            dek = [mgr unwrapDEKWithKEK:aesKek
                              algorithm:@"aes-256-gcm"
                                  error:&err];
        } else {
            dek = [mgr unwrapDEKWithKEK:mlkemPriv
                              algorithm:@"ml-kem-1024"
                                  error:&err];
        }
        PASS(dek != nil, "%s: unwrap succeeded", name.UTF8String);
        PASS(dek != nil && [dekHex(dek) isEqualToString:expected],
             "%s: ObjC recovered the expected DEK written by %s",
             name.UTF8String, writer.UTF8String);

        if (isAes && [writer isEqualToString:@"py"]) sawPythonAes = YES;
    }

    // The historic crash case: a Python-written uint8 dek_wrapped read
    // by ObjC. Must be present and have passed above.
    PASS(sawPythonAes,
         "Python-written AES dek_wrapped present and read by ObjC "
         "(the historic crash case the fix addresses)");
}
