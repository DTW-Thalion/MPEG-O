// TestCipherSuite.m — v0.7 M48 catalog + key-validation tests.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Protection/TTIOCipherSuite.h"

static NSData *zeros(NSUInteger n)
{
    return [NSMutableData dataWithLength:n];
}

void testCipherSuite(void)
{
    // ── Active defaults ──
    PASS([TTIOCipherSuite isSupported:@"aes-256-gcm"],
         "M48: aes-256-gcm is supported");
    PASS([TTIOCipherSuite isSupported:@"hmac-sha256"],
         "M48: hmac-sha256 is supported");
    PASS([TTIOCipherSuite isSupported:@"sha-256"],
         "M48: sha-256 is supported");

    // ── Reserved vs active (post-M49) ──
    PASS([TTIOCipherSuite isRegistered:@"ml-kem-1024"]
         && [TTIOCipherSuite isSupported:@"ml-kem-1024"],
         "M48/M49: ml-kem-1024 is now active");
    PASS([TTIOCipherSuite isRegistered:@"ml-dsa-87"]
         && [TTIOCipherSuite isSupported:@"ml-dsa-87"],
         "M48/M49: ml-dsa-87 is now active");
    PASS([TTIOCipherSuite isRegistered:@"shake256"]
         && ![TTIOCipherSuite isSupported:@"shake256"],
         "M48/M49: shake256 still reserved");

    // ── Unknown ──
    PASS(![TTIOCipherSuite isRegistered:@"chacha20-poly1305"],
         "M48: unknown algorithm is not in catalog");
    PASS(![TTIOCipherSuite isSupported:@"garbage"],
         "M48: garbage algorithm is not supported");

    // ── Metadata ──
    PASS([TTIOCipherSuite keyLength:@"aes-256-gcm"] == 32,
         "M48: aes-256-gcm key length is 32");
    PASS([TTIOCipherSuite nonceLength:@"aes-256-gcm"] == 12,
         "M48: aes-256-gcm nonce length is 12");
    PASS([TTIOCipherSuite tagLength:@"aes-256-gcm"] == 16,
         "M48: aes-256-gcm tag length is 16");
    PASS([TTIOCipherSuite keyLength:@"hmac-sha256"] == -1,
         "M48: hmac-sha256 reports variable key length (-1)");
    PASS([TTIOCipherSuite tagLength:@"hmac-sha256"] == 32,
         "M48: hmac-sha256 tag length is 32 (SHA-256 output)");

    // ── validateKey: AES-256-GCM ──
    NSError *err = nil;
    PASS([TTIOCipherSuite validateKey:zeros(32) algorithm:@"aes-256-gcm" error:&err],
         "M48: 32-byte key validates for aes-256-gcm");
    PASS(err == nil, "M48: no error on valid key");
    err = nil;
    PASS(![TTIOCipherSuite validateKey:zeros(31) algorithm:@"aes-256-gcm" error:&err],
         "M48: 31-byte key rejected for aes-256-gcm");
    PASS(err != nil, "M48: error populated on length mismatch");

    // ── validateKey: HMAC-SHA256 (variable-length) ──
    err = nil;
    PASS([TTIOCipherSuite validateKey:[@"k" dataUsingEncoding:NSUTF8StringEncoding]
                             algorithm:@"hmac-sha256"
                                 error:&err],
         "M48: HMAC accepts 1-byte key");
    err = nil;
    PASS(![TTIOCipherSuite validateKey:[NSData data]
                              algorithm:@"hmac-sha256"
                                  error:&err],
         "M48: HMAC rejects empty key");

    // ── validateKey: asymmetric (M49) / unknown ──
    err = nil;
    PASS(![TTIOCipherSuite validateKey:zeros(1568)
                              algorithm:@"ml-kem-1024"
                                  error:&err],
         "M49: asymmetric algorithm rejected by validateKey:");
    PASS(err != nil
         && [err.localizedDescription containsString:@"asymmetric"],
         "M49: asymmetric-rejection error mentions 'asymmetric'");
    err = nil;
    PASS(![TTIOCipherSuite validateKey:zeros(32)
                              algorithm:@"chacha20-poly1305"
                                  error:&err],
         "M48: unknown algorithm rejected by validateKey:");

    // ── Catalog enumeration ──
    NSArray<NSString *> *all = [TTIOCipherSuite allAlgorithms];
    PASS(all.count >= 6, "M48: catalog contains ≥6 algorithms");
    PASS([all containsObject:@"aes-256-gcm"], "M48: catalog includes aes-256-gcm");
    PASS([all containsObject:@"ml-dsa-87"], "M48: catalog includes ml-dsa-87");
}
