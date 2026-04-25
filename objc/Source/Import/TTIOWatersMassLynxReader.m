/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIOWatersMassLynxReader.h"
#import "TTIOMzMLReader.h"
#import <stdlib.h>
#import <unistd.h>

static NSString *const kMassLynxErrorDomain = @"TTIOWatersMassLynxReader";

static NSError *masslynxError(NSInteger code, NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:kMassLynxErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// Read the current value of env var ``name`` fresh from libc —
// NSProcessInfo snapshots environ at process start in GNUstep.
static NSString *mlxEnvValue(const char *name)
{
    const char *v = getenv(name);
    return v ? [NSString stringWithUTF8String:v] : nil;
}

static NSString *mlxPathLookup(NSString *name)
{
    NSString *pathEnv = mlxEnvValue("PATH");
    if (!pathEnv) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [pathEnv componentsSeparatedByString:@":"]) {
        if (dir.length == 0) continue;
        NSString *candidate = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDir] && !isDir) {
            if ([fm isExecutableFileAtPath:candidate]) return candidate;
        }
    }
    return nil;
}

static NSArray<NSString *> *mlxResolveBinary(NSString *explicit, NSError **error)
{
    NSFileManager *fm = [NSFileManager defaultManager];

    if (explicit.length > 0) {
        if (![fm isExecutableFileAtPath:explicit]) {
            if (error) *error = masslynxError(2,
                @"MassLynx converter not found or not executable: %@", explicit);
            return nil;
        }
        if ([explicit.lowercaseString hasSuffix:@".exe"]) {
            NSString *mono = mlxPathLookup(@"mono");
            if (!mono) {
                if (error) *error = masslynxError(3,
                    @"%@ requires mono, which is not on PATH.", explicit);
                return nil;
            }
            return @[mono, explicit];
        }
        return @[explicit];
    }

    NSString *envVar = mlxEnvValue("MASSLYNXRAW");
    if (envVar.length > 0) {
        if (![fm isExecutableFileAtPath:envVar]) {
            if (error) *error = masslynxError(2,
                @"MASSLYNXRAW env var points to missing or non-executable "
                @"binary: %@", envVar);
            return nil;
        }
        if ([envVar.lowercaseString hasSuffix:@".exe"]) {
            NSString *mono = mlxPathLookup(@"mono");
            if (!mono) {
                if (error) *error = masslynxError(3,
                    @"%@ requires mono, which is not on PATH.", envVar);
                return nil;
            }
            return @[mono, envVar];
        }
        return @[envVar];
    }

    NSString *native = mlxPathLookup(@"masslynxraw");
    if (native) return @[native];

    NSString *winExe = mlxPathLookup(@"MassLynxRaw.exe");
    if (winExe) {
        NSString *mono = mlxPathLookup(@"mono");
        if (!mono) {
            if (error) *error = masslynxError(3,
                @"Found MassLynxRaw.exe but mono is not on PATH.");
            return nil;
        }
        return @[mono, winExe];
    }

    if (error) *error = masslynxError(1,
        @"MassLynx converter ('masslynxraw' or 'MassLynxRaw.exe') not "
        @"found on PATH and MASSLYNXRAW not set. See docs/vendor-formats.md "
        @"for installation instructions.");
    return nil;
}

@implementation TTIOWatersMassLynxReader

+ (TTIOSpectralDataset *)readFromDirectoryPath:(NSString *)path
                                           error:(NSError **)error
{
    return [self readFromDirectoryPath:path converter:nil error:error];
}

+ (TTIOSpectralDataset *)readFromDirectoryPath:(NSString *)path
                                       converter:(NSString *)converter
                                           error:(NSError **)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        if (error) *error = masslynxError(4,
            @"Waters .raw directory not found: %@", path);
        return nil;
    }

    NSArray<NSString *> *cmdPrefix = mlxResolveBinary(converter, error);
    if (!cmdPrefix) return nil;

    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ttio_masslynx_%d_%ld",
         (int)getpid(), (long)[[NSDate date] timeIntervalSince1970]]];
    if (![fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES
                         attributes:nil error:error]) {
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = cmdPrefix[0];
    NSMutableArray *args = [NSMutableArray array];
    if (cmdPrefix.count > 1) {
        [args addObjectsFromArray:[cmdPrefix subarrayWithRange:
            NSMakeRange(1, cmdPrefix.count - 1)]];
    }
    [args addObjectsFromArray:@[@"-i", path, @"-o", tmpDir]];
    task.arguments = args;
    task.standardOutput = [NSPipe pipe];
    task.standardError  = [NSPipe pipe];
    [task launch];
    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        NSData *errData = [[task.standardError fileHandleForReading] readDataToEndOfFile];
        NSString *errStr = [[NSString alloc] initWithData:errData
                                                  encoding:NSUTF8StringEncoding] ?: @"";
        [fm removeItemAtPath:tmpDir error:NULL];
        if (error) *error = masslynxError(6,
            @"MassLynx converter exited %d: %@",
            (int)task.terminationStatus, errStr);
        return nil;
    }

    // Waters .raw "filenames" are directories — strip a trailing
    // ".raw" from the basename to match the converter's usual naming.
    NSString *baseName = [[path lastPathComponent] stringByDeletingPathExtension];
    NSString *mzmlPath = [tmpDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.mzML", baseName]];
    if (![fm fileExistsAtPath:mzmlPath]) {
        NSArray *contents = [fm contentsOfDirectoryAtPath:tmpDir error:NULL];
        NSString *found = nil;
        for (NSString *entry in contents) {
            if ([entry.lowercaseString hasSuffix:@".mzml"]) {
                found = [tmpDir stringByAppendingPathComponent:entry];
                break;
            }
        }
        if (!found) {
            [fm removeItemAtPath:tmpDir error:NULL];
            if (error) *error = masslynxError(7,
                @"MassLynx converter produced no mzML in %@", tmpDir);
            return nil;
        }
        mzmlPath = found;
    }

    TTIOSpectralDataset *ds = [TTIOMzMLReader readFromFilePath:mzmlPath error:error];
    [fm removeItemAtPath:tmpDir error:NULL];
    return ds;
}

@end
