/*
 * TtioDekEnvelope — dataset-level envelope-encryption dek_wrapped
 * cross-language conformance CLI. Parallel to Python
 * ttio.tools.dek_envelope_cli and Java
 * global.thalion.ttio.tools.DekEnvelopeCli.
 *
 * Proves a /protection/key_info/dek_wrapped blob written by one
 * language is read AND unwrapped by the others — guarding the bug
 * fixed on fix/dek-wrapped-xlang where Java/ObjC stored dek_wrapped as
 * an int32-padded dataset while Python stored the spec-compliant
 * uint8[N] exact-length blob, corrupting cross-language reads. All
 * three now write uint8[N].
 *
 * Usage:
 *   TtioDekEnvelope wrap   out.tio kek-file [--algorithm aes-256-gcm|ml-kem-1024]
 *   TtioDekEnvelope unwrap in.tio  kek-file [--algorithm aes-256-gcm|ml-kem-1024]
 *
 * wrap generates a fresh random DEK (the production path), wraps it
 * under the KEK read from kek-file, persists key_info, and prints the
 * plaintext DEK as lowercase hex. unwrap opens the file, unwraps with
 * the KEK, and prints the recovered DEK hex. For aes-256-gcm the KEK
 * file is a 32-byte symmetric key; for ml-kem-1024 it is the 1568-byte
 * encapsulation public key (wrap) / 3168-byte decapsulation private
 * key (unwrap).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "HDF5/TTIOHDF5File.h"
#import "Protection/TTIOKeyRotationManager.h"
#include <stdio.h>
#include <string.h>

static NSString *hexEncode(NSData *data)
{
    const unsigned char *bytes = data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [s appendFormat:@"%02x", bytes[i]];
    }
    return s;
}

static NSData *readKekFile(NSString *path, NSString *algorithm)
{
    NSData *k = [NSData dataWithContentsOfFile:path];
    if (!k) {
        fprintf(stderr, "cannot read KEK file %s\n", path.UTF8String);
        exit(2);
    }
    if ([algorithm isEqualToString:@"aes-256-gcm"] && k.length != 32) {
        fprintf(stderr, "aes-256-gcm KEK file must be 32 bytes, got %lu\n",
                (unsigned long)k.length);
        exit(2);
    }
    return k;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr,
                "usage: TtioDekEnvelope (wrap|unwrap) <file.tio> <kek-file> "
                "[--algorithm aes-256-gcm|ml-kem-1024]\n");
            return 2;
        }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        NSString *kekPath = [NSString stringWithUTF8String:argv[3]];
        NSString *algorithm = @"aes-256-gcm";
        for (int i = 4; i < argc; i++) {
            if (strcmp(argv[i], "--algorithm") == 0 && i + 1 < argc) {
                algorithm = [NSString stringWithUTF8String:argv[++i]];
            }
        }

        NSData *kek = readKekFile(kekPath, algorithm);
        NSError *err = nil;

        if ([cmd isEqualToString:@"wrap"]) {
            TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
            if (!f) {
                fprintf(stderr, "create failed: %s\n",
                        err.localizedDescription.UTF8String);
                return 1;
            }
            TTIOKeyRotationManager *mgr =
                [TTIOKeyRotationManager managerWithFile:f];
            NSData *dek = [mgr enableEnvelopeEncryptionWithKEK:kek
                                                         kekId:@"kek-xlang"
                                                     algorithm:algorithm
                                                         error:&err];
            if (!dek) {
                fprintf(stderr, "wrap failed: %s\n",
                        err.localizedDescription.UTF8String);
                return 1;
            }
            printf("%s\n", hexEncode(dek).UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"unwrap"]) {
            TTIOHDF5File *f = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
            if (!f) {
                fprintf(stderr, "open failed: %s\n",
                        err.localizedDescription.UTF8String);
                return 1;
            }
            TTIOKeyRotationManager *mgr =
                [TTIOKeyRotationManager managerWithFile:f];
            NSData *dek = [mgr unwrapDEKWithKEK:kek
                                      algorithm:algorithm
                                          error:&err];
            if (!dek) {
                fprintf(stderr, "unwrap failed: %s\n",
                        err.localizedDescription.UTF8String);
                return 1;
            }
            printf("%s\n", hexEncode(dek).UTF8String);
            return 0;
        }

        fprintf(stderr, "unknown command: %s\n", cmd.UTF8String);
        return 2;
    }
}
