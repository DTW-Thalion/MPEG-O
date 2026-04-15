#import "MPGOVerifier.h"
#import "MPGOSignatureManager.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"
#import <hdf5.h>

@implementation MPGOVerifier

static BOOL datasetHasSignature(NSString *datasetPath, NSString *filePath)
{
    MPGOHDF5File *file = [MPGOHDF5File openReadOnlyAtPath:filePath error:NULL];
    if (!file) return NO;
    hid_t did = H5Dopen2([file rootGroup].groupId, [datasetPath UTF8String], H5P_DEFAULT);
    if (did < 0) { [file close]; return NO; }
    BOOL has = (H5Aexists(did, "mpgo_signature") > 0);
    H5Dclose(did);
    [file close];
    return has;
}

static BOOL runHasProvenanceSignature(NSString *runPath, NSString *filePath)
{
    MPGOHDF5File *file = [MPGOHDF5File openReadOnlyAtPath:filePath error:NULL];
    if (!file) return NO;
    hid_t gid = H5Gopen2([file rootGroup].groupId, [runPath UTF8String], H5P_DEFAULT);
    if (gid < 0) { [file close]; return NO; }
    BOOL has = (H5Aexists(gid, "provenance_signature") > 0);
    H5Gclose(gid);
    [file close];
    return has;
}

+ (MPGOVerificationStatus)verifyDataset:(NSString *)datasetPath
                                 inFile:(NSString *)filePath
                                withKey:(NSData *)key
                                  error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) *error = MPGOMakeError(MPGOErrorFileNotFound, @"file not found");
        return MPGOVerificationStatusError;
    }
    if (!datasetHasSignature(datasetPath, filePath)) {
        return MPGOVerificationStatusNotSigned;
    }
    NSError *innerErr = nil;
    BOOL ok = [MPGOSignatureManager verifyDataset:datasetPath
                                           inFile:filePath
                                          withKey:key
                                            error:&innerErr];
    if (ok) return MPGOVerificationStatusValid;
    if (error) *error = innerErr;
    return MPGOVerificationStatusInvalid;
}

+ (MPGOVerificationStatus)verifyProvenanceInRun:(NSString *)runPath
                                         inFile:(NSString *)filePath
                                        withKey:(NSData *)key
                                          error:(NSError **)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) *error = MPGOMakeError(MPGOErrorFileNotFound, @"file not found");
        return MPGOVerificationStatusError;
    }
    if (!runHasProvenanceSignature(runPath, filePath)) {
        return MPGOVerificationStatusNotSigned;
    }
    NSError *innerErr = nil;
    BOOL ok = [MPGOSignatureManager verifyProvenanceInRun:runPath
                                                   inFile:filePath
                                                  withKey:key
                                                    error:&innerErr];
    if (ok) return MPGOVerificationStatusValid;
    if (error) *error = innerErr;
    return MPGOVerificationStatusInvalid;
}

@end
