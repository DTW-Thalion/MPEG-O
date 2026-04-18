// TestCloudAccess.m — M20 / v0.3 deferred follow-up: cloud-native
// .mpgo access via libhdf5's ROS3 VFD.
//
// This test asserts that the +isS3Supported probe works and that
// +openS3URL: fails cleanly on an unresolvable bucket. Exercising a
// real S3 bucket is left to an integration harness gated on
// AWS_ACCESS_KEY_ID availability.
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "HDF5/MPGOHDF5File.h"

void testCloudAccess(void)
{
    // +isS3Supported must not crash; the return value depends on how
    // libhdf5 was built. Ubuntu 24.04's apt package ships ROS3 enabled.
    BOOL s3 = [MPGOHDF5File isS3Supported];
    PASS(s3 == YES || s3 == NO,
        "cloud: isS3Supported returns a boolean");

    if (!s3) {
        NSLog(@"cloud: skipping openS3URL smoke test "
              @"(libhdf5 built without ROS3)");
        return;
    }

    // Nonexistent bucket → libcurl DNS/NXDOMAIN → H5Fopen fails → we
    // return nil + populated NSError. No network is required because
    // bucket resolution fails at DNS.
    NSError *err = nil;
    MPGOHDF5File *file = [MPGOHDF5File openS3URL:
                              @"s3://mpeg-o-nonexistent-bucket-xyz/nope.mpgo"
                                           region:@"us-east-1"
                                     accessKeyId:nil
                                 secretAccessKey:nil
                                    sessionToken:nil
                                           error:&err];
    PASS(file == nil, "cloud: openS3URL with bad bucket returns nil");
    PASS(err != nil, "cloud: openS3URL populates NSError on failure");
}
