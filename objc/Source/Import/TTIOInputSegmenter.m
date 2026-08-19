/* SPDX-License-Identifier: LGPL-3.0-or-later */
#import "Import/TTIOInputSegmenter.h"

@implementation TTIOInputSegmenter

+ (TTIOInputMode)modeForPath:(NSString *)path
{
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
        return TTIOInputModePipeline;
    }
    NSDictionary *att = [fm attributesOfItemAtPath:path error:NULL];
    if (![att.fileType isEqualToString:NSFileTypeRegular]) {
        return TTIOInputModePipeline;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil) return TTIOInputModePipeline;
    NSData *magic = [fh readDataOfLength:2];
    [fh closeFile];
    if (magic.length == 2) {
        const uint8_t *m = magic.bytes;
        if (m[0] == 0x1f && m[1] == 0x8b) return TTIOInputModePipeline;
    }
    return TTIOInputModeShard;
}

@end
