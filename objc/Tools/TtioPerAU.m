/*
 * TtioPerAU — v1.0 cross-language conformance CLI for per-AU
 *             encryption. Parallel to Python
 *             ttio.tools.per_au_cli and Java
 *             com.dtwthalion.ttio.tools.PerAUCli.
 *
 * All three implementations emit byte-equivalent outputs given
 * identical inputs. ``decrypt`` produces an "MPAD" binary dump with
 * sorted u16-prefixed keys and u32-prefixed byte payloads (see the
 * Java PerAUCli Javadoc for the wire layout); byte-level equality
 * on the .mpad artefact validates the implementations.
 *
 * Usage:
 *   TtioPerAU encrypt  in.tio out.tio keyfile [--headers]
 *   TtioPerAU decrypt  in.tio out.mpad keyfile
 *   TtioPerAU send     in.tio out.tis
 *   TtioPerAU recv     in.tis out.tio
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Protection/TTIOPerAUFile.h"
#import "Protection/TTIOPerAUEncryption.h"
#import "Transport/TTIOEncryptedTransport.h"
#import "Transport/TTIOTransportWriter.h"
#include <stdio.h>
#include <string.h>

static NSData *readKeyFile(NSString *path)
{
    NSData *k = [NSData dataWithContentsOfFile:path];
    if (!k || k.length != 32) {
        fprintf(stderr, "key file must be 32 bytes, got %lu\n",
                (unsigned long)(k ? k.length : 0));
        exit(2);
    }
    return k;
}

static BOOL copyFile(NSString *src, NSString *dst)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:NULL];
    return [fm copyItemAtPath:src toPath:dst error:NULL];
}

static void appendU16LE(NSMutableData *buf, uint16_t v)
{
    uint8_t b[2] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF) };
    [buf appendBytes:b length:2];
}
static void appendU32LE(NSMutableData *buf, uint32_t v)
{
    uint8_t b[4];
    b[0] = (uint8_t)(v & 0xFF);
    b[1] = (uint8_t)((v >> 8) & 0xFF);
    b[2] = (uint8_t)((v >> 16) & 0xFF);
    b[3] = (uint8_t)((v >> 24) & 0xFF);
    [buf appendBytes:b length:4];
}

static NSString *jsonDouble(double d)
{
    if (d == floor(d) && !isinf(d)) {
        return [NSString stringWithFormat:@"%.1f", d];
    }
    // Emit using Python's repr(float) semantics: shortest round-trip
    // decimal representation. NSNumber's stringValue satisfies this
    // for finite, non-integer doubles.
    return [NSString stringWithFormat:@"%.17g", d];
}

static NSString *headersJson(NSArray *rows)
{
    NSMutableString *out = [NSMutableString stringWithString:@"["];
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (i > 0) [out appendString:@","];
        TTIOAUHeaderPlaintext *r = rows[i];
        [out appendString:@"{"];
        [out appendFormat:@"\"acquisition_mode\":%u", (unsigned)r.acquisitionMode];
        [out appendFormat:@",\"base_peak_intensity\":%@", jsonDouble(r.basePeakIntensity)];
        [out appendFormat:@",\"ion_mobility\":%@", jsonDouble(r.ionMobility)];
        [out appendFormat:@",\"ms_level\":%u", (unsigned)r.msLevel];
        [out appendFormat:@",\"polarity\":%d", (int)r.polarity];
        [out appendFormat:@",\"precursor_charge\":%u", (unsigned)r.precursorCharge];
        [out appendFormat:@",\"precursor_mz\":%@", jsonDouble(r.precursorMz)];
        [out appendFormat:@",\"retention_time\":%@", jsonDouble(r.retentionTime)];
        [out appendString:@"}"];
    }
    [out appendString:@"]"];
    return out;
}

static int cmdEncrypt(int argc, const char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: encrypt <in> <out> <key> [--headers]\n"); return 2; }
    NSString *in = @(argv[2]);
    NSString *out = @(argv[3]);
    NSString *keyPath = @(argv[4]);
    BOOL headers = (argc >= 6) && strcmp(argv[5], "--headers") == 0;
    if (!copyFile(in, out)) { fprintf(stderr, "copy failed\n"); return 1; }
    NSError *err = nil;
    BOOL ok = [TTIOPerAUFile encryptFilePath:out
                                          key:readKeyFile(keyPath)
                               encryptHeaders:headers
                                 providerName:nil
                                        error:&err];
    if (!ok) {
        fprintf(stderr, "encrypt failed: %s\n",
                err.localizedDescription.UTF8String ?: "unknown");
        return 1;
    }
    return 0;
}

static int cmdDecrypt(int argc, const char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: decrypt <in> <out> <key>\n"); return 2; }
    NSString *in = @(argv[2]);
    NSString *out = @(argv[3]);
    NSString *keyPath = @(argv[4]);
    NSError *err = nil;
    NSDictionary *plain = [TTIOPerAUFile decryptFilePath:in
                                                      key:readKeyFile(keyPath)
                                             providerName:nil
                                                    error:&err];
    if (!plain) {
        fprintf(stderr, "decrypt failed: %s\n",
                err.localizedDescription.UTF8String ?: "unknown");
        return 1;
    }

    NSMutableDictionary<NSString *, NSData *> *entries = [NSMutableDictionary dictionary];
    for (NSString *runName in plain) {
        NSDictionary *run = plain[runName];
        for (NSString *key in run) {
            NSString *outKey;
            NSData *bytes;
            if ([key isEqualToString:@"__au_headers__"]) {
                outKey = [NSString stringWithFormat:@"%@__au_headers_json", runName];
                bytes = [headersJson(run[key]) dataUsingEncoding:NSUTF8StringEncoding];
            } else {
                outKey = [NSString stringWithFormat:@"%@__%@", runName, key];
                bytes = run[key];   // NSData float64 LE
            }
            entries[outKey] = bytes;
        }
    }

    NSArray *sortedKeys =
        [entries.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableData *buf = [NSMutableData data];
    [buf appendBytes:"MPAD" length:4];
    appendU32LE(buf, (uint32_t)sortedKeys.count);
    for (NSString *key in sortedKeys) {
        NSData *kb = [key dataUsingEncoding:NSUTF8StringEncoding];
        appendU16LE(buf, (uint16_t)kb.length);
        [buf appendData:kb];
        NSData *v = entries[key];
        appendU32LE(buf, (uint32_t)v.length);
        [buf appendData:v];
    }
    if (![buf writeToFile:out atomically:YES]) {
        fprintf(stderr, "write failed\n");
        return 1;
    }
    return 0;
}

static int cmdSend(int argc, const char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: send <in> <out>\n"); return 2; }
    NSString *in = @(argv[2]);
    NSString *out = @(argv[3]);
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithOutputPath:out];
    NSError *err = nil;
    BOOL ok = [TTIOEncryptedTransport writeEncryptedDataset:in
                                                       writer:tw
                                                 providerName:nil
                                                        error:&err];
    [tw close];
    if (!ok) {
        fprintf(stderr, "send failed: %s\n",
                err.localizedDescription.UTF8String ?: "unknown");
        return 1;
    }
    return 0;
}

static int cmdRecv(int argc, const char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: recv <in> <out>\n"); return 2; }
    NSString *in = @(argv[2]);
    NSString *out = @(argv[3]);
    NSData *stream = [NSData dataWithContentsOfFile:in];
    if (!stream) { fprintf(stderr, "read %s failed\n", argv[2]); return 1; }
    NSError *err = nil;
    BOOL ok = [TTIOEncryptedTransport readEncryptedToPath:out
                                                fromStream:stream
                                               providerName:nil
                                                      error:&err];
    if (!ok) {
        fprintf(stderr, "recv failed: %s\n",
                err.localizedDescription.UTF8String ?: "unknown");
        return 1;
    }
    return 0;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: TtioPerAU <encrypt|decrypt|send|recv> ...\n");
            return 2;
        }
        const char *cmd = argv[1];
        if (strcmp(cmd, "encrypt") == 0) return cmdEncrypt(argc, argv);
        if (strcmp(cmd, "decrypt") == 0) return cmdDecrypt(argc, argv);
        if (strcmp(cmd, "send") == 0)    return cmdSend(argc, argv);
        if (strcmp(cmd, "recv") == 0)    return cmdRecv(argc, argv);
        fprintf(stderr, "unknown command: %s\n", cmd);
        return 2;
    }
}
