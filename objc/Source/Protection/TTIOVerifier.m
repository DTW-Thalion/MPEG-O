/*
 * TTIOVerifier.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOVerifier
 * Declared In:   Protection/TTIOVerifier.h
 *
 * Higher-level verification API that collapses sign-and-verify
 * outcomes into TTIOVerificationStatus enum values.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOVerifier.h"
#import "TTIOSignatureManager.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <hdf5.h>

@implementation TTIOVerifier

static BOOL datasetHasSignature(NSString *datasetPath, NSString *filePath)
{
    TTIOHDF5File *file = [TTIOHDF5File openReadOnlyAtPath:filePath error:NULL];
    if (!file) return NO;
    hid_t did = H5Dopen2([file rootGroup].groupId, [datasetPath UTF8String], H5P_DEFAULT);
    if (did < 0) { [file close]; return NO; }
    BOOL has = (H5Aexists(did, "ttio_signature") > 0);
    H5Dclose(did);
    [file close];
    return has;
}

static BOOL runHasProvenanceSignature(NSString *runPath, NSString *filePath)
{
    TTIOHDF5File *file = [TTIOHDF5File openReadOnlyAtPath:filePath error:NULL];
    if (!file) return NO;
    hid_t gid = H5Gopen2([file rootGroup].groupId, [runPath UTF8String], H5P_DEFAULT);
    if (gid < 0) { [file close]; return NO; }
    BOOL has = (H5Aexists(gid, "provenance_signature") > 0);
    H5Gclose(gid);
    [file close];
    return has;
}

+ (TTIOVerificationStatus)verifyDataset:(NSString *)datasetPath
                                 inFile:(NSString *)filePath
                                withKey:(NSData *)key
                                  error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound, @"file not found");
        return TTIOVerificationStatusError;
    }
    if (!datasetHasSignature(datasetPath, filePath)) {
        return TTIOVerificationStatusNotSigned;
    }
    NSError *innerErr = nil;
    BOOL ok = [TTIOSignatureManager verifyDataset:datasetPath
                                           inFile:filePath
                                          withKey:key
                                            error:&innerErr];
    if (ok) return TTIOVerificationStatusValid;
    if (error) *error = innerErr;
    return TTIOVerificationStatusInvalid;
}

+ (TTIOVerificationStatus)verifyProvenanceInRun:(NSString *)runPath
                                         inFile:(NSString *)filePath
                                        withKey:(NSData *)key
                                          error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) *error = TTIOMakeError(TTIOErrorFileNotFound, @"file not found");
        return TTIOVerificationStatusError;
    }
    if (!runHasProvenanceSignature(runPath, filePath)) {
        return TTIOVerificationStatusNotSigned;
    }
    NSError *innerErr = nil;
    BOOL ok = [TTIOSignatureManager verifyProvenanceInRun:runPath
                                                   inFile:filePath
                                                  withKey:key
                                                    error:&innerErr];
    if (ok) return TTIOVerificationStatusValid;
    if (error) *error = innerErr;
    return TTIOVerificationStatusInvalid;
}

@end
