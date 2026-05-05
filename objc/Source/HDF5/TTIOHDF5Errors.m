/*
 * TTIOHDF5Errors.m
 * TTI-O Objective-C Implementation
 *
 * Declared In:   HDF5/TTIOHDF5Errors.h
 *
 * NSError factory and TTIOErrorDomain string.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOHDF5Errors.h"

NSString *const TTIOErrorDomain = @"org.tio.TTIOErrorDomain";

NSError *TTIOMakeError(TTIOErrorCode code, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    return [NSError errorWithDomain:TTIOErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}
