/*
 * TTIOThermoRawReader.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOThermoRawReader
 * Inherits From: NSObject
 * Conforms To:   NSObject (NSObject)
 * Declared In:   Import/TTIOThermoRawReader.h
 *
 * Public ObjC entry point for reading Thermo Fisher .raw files. The
 * interface is fixed; current ObjC build returns nil with an
 * NSError describing the missing Thermo RawFileReader SDK
 * dependency.
 *
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "TTIOThermoRawReader.h"
#import "TTIOMzMLReader.h"
#import <stdlib.h>
#import <unistd.h>

static NSString *const kThermoErrorDomain = @"TTIOThermoRawReader";

static NSError *thermoError(NSInteger code, NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:kThermoErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// Return current value of env var `name`, reading fresh from libc.
// NSProcessInfo -environment is snapshotted at process start in some
// Foundation implementations, which would miss setenv() calls.
static NSString *envValue(const char *name)
{
    const char *v = getenv(name);
    return v ? [NSString stringWithUTF8String:v] : nil;
}

// Split PATH on ':' and look for `name` in each directory.
static NSString *pathLookup(NSString *name)
{
    NSString *pathEnv = envValue("PATH");
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

// Resolve the binary as [interpreter?, binary] argv prefix.
static NSArray<NSString *> *resolveBinary(NSError **error)
{
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *envVar = envValue("THERMORAWFILEPARSER");
    if (envVar.length > 0) {
        if (![fm isExecutableFileAtPath:envVar]) {
            if (error) *error = thermoError(2,
                @"THERMORAWFILEPARSER env var points to missing or "
                @"non-executable binary: %@", envVar);
            return nil;
        }
        if ([envVar.lowercaseString hasSuffix:@".exe"]) {
            NSString *mono = pathLookup(@"mono");
            if (!mono) {
                if (error) *error = thermoError(3,
                    @"%@ requires mono, which is not on PATH.", envVar);
                return nil;
            }
            return @[mono, envVar];
        }
        return @[envVar];
    }

    NSString *native = pathLookup(@"ThermoRawFileParser");
    if (native) return @[native];

    NSString *dotnet = pathLookup(@"ThermoRawFileParser.exe");
    if (dotnet) {
        NSString *mono = pathLookup(@"mono");
        if (!mono) {
            if (error) *error = thermoError(3,
                @"Found ThermoRawFileParser.exe but mono is not on PATH.");
            return nil;
        }
        return @[mono, dotnet];
    }

    if (error) *error = thermoError(1,
        @"ThermoRawFileParser not found on PATH and THERMORAWFILEPARSER not set. "
        @"See docs/vendor-formats.md for installation instructions.");
    return nil;
}

@implementation TTIOThermoRawReader

+ (TTIOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        if (error) *error = thermoError(4, @"Thermo .raw file not found: %@", path);
        return nil;
    }

    NSArray<NSString *> *cmdPrefix = resolveBinary(error);
    if (!cmdPrefix) return nil;

    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ttio_thermo_%d_%ld",
         (int)getpid(), (long)[[NSDate date] timeIntervalSince1970]]];
    if (![fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES
                         attributes:nil error:error]) {
        return nil;
    }

    // All binaries in cmdPrefix are validated executable by resolveBinary,
    // so NSTask -launch should not raise under GNUstep's implementation.
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = cmdPrefix[0];
    NSMutableArray *args = [NSMutableArray array];
    if (cmdPrefix.count > 1) {
        [args addObjectsFromArray:[cmdPrefix subarrayWithRange:
            NSMakeRange(1, cmdPrefix.count - 1)]];
    }
    [args addObjectsFromArray:@[@"-i", path, @"-o", tmpDir, @"-f", @"2"]];
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
        if (error) *error = thermoError(6,
            @"ThermoRawFileParser exited %d: %@",
            (int)task.terminationStatus, errStr);
        return nil;
    }

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
            if (error) *error = thermoError(7,
                @"ThermoRawFileParser produced no mzML in %@", tmpDir);
            return nil;
        }
        mzmlPath = found;
    }

    TTIOSpectralDataset *ds = [TTIOMzMLReader readFromFilePath:mzmlPath error:error];
    [fm removeItemAtPath:tmpDir error:NULL];
    return ds;
}

@end
