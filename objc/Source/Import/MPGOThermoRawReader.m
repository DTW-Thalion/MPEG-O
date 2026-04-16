/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#import "MPGOThermoRawReader.h"

@implementation MPGOThermoRawReader

+ (MPGOSpectralDataset *)readFromFilePath:(NSString *)path error:(NSError **)error
{
    if (error) {
        *error = [NSError errorWithDomain:@"MPGOThermoRawReader"
                                      code:1
                                  userInfo:@{NSLocalizedDescriptionKey:
            @"Thermo .raw import is not yet implemented. It requires the "
            @"Thermo RawFileReader SDK (proprietary; free-as-in-beer license "
            @"from Thermo Fisher Scientific). See docs/vendor-formats.md for "
            @"integration guidance. Targeted for MPEG-O v0.5+."}];
    }
    return nil;
}

@end
