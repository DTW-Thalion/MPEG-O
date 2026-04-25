#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Image/TTIOMSImage.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <unistd.h>

static NSString *imgPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_img_%d_%@.tio",
            (int)getpid(), suffix];
}

static double cubeValueAt(NSUInteger x, NSUInteger y, NSUInteger s,
                          NSUInteger width, NSUInteger spectralPoints)
{
    // Deterministic synthetic cube — easy to verify per-tile.
    return (double)(x * 1000 + y * 13) + (double)s * 0.001;
}

void testMSImage(void)
{
    const NSUInteger W = 64, H = 64, SP = 8, TS = 32;

    // ---- build synthetic 64x64x8 cube ----
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    double *p = cube.mutableBytes;
    for (NSUInteger y = 0; y < H; y++) {
        for (NSUInteger x = 0; x < W; x++) {
            for (NSUInteger s = 0; s < SP; s++) {
                p[(y * W + x) * SP + s] = cubeValueAt(x, y, s, W, SP);
            }
        }
    }

    TTIOMSImage *img = [[TTIOMSImage alloc] initWithWidth:W
                                                   height:H
                                           spectralPoints:SP
                                                 tileSize:TS
                                                     cube:cube];
    PASS(img != nil, "64x64x8 MSImage constructible");
    PASS(img.tileSize == TS, "tile size stored");
    PASS(img.cube.length == W * H * SP * sizeof(double), "cube buffer size matches");

    // ---- write ----
    NSString *path = imgPath(@"image");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err],
         "64x64 MSImage writes to HDF5");
    PASS(err == nil, "no error on write");

    // ---- reopen + full round-trip equality ----
    TTIOMSImage *back = [TTIOMSImage readFromFilePath:path error:&err];
    PASS(back != nil, "MSImage reads back");
    PASS(back.width == W && back.height == H && back.spectralPoints == SP,
         "dimensions round-trip");
    PASS(back.tileSize == TS, "tile size round-trips");
    PASS([back.cube isEqualToData:cube], "full cube bytes round-trip exactly");
    PASS([back isEqual:img], "MSImage isEqual: original after round-trip");

    // ---- tile read: (0..31, 0..31) — top-left tile ----
    NSData *tileTL = [TTIOMSImage readTileFromFilePath:path
                                                   atX:0 y:0
                                                 width:TS
                                                height:TS
                                                 error:&err];
    PASS(tileTL != nil, "top-left tile reads");
    PASS(tileTL.length == TS * TS * SP * sizeof(double),
         "tile byte length is tileSize*tileSize*spectralPoints*8");

    const double *tp = tileTL.bytes;
    BOOL ok = YES;
    for (NSUInteger ty = 0; ty < TS && ok; ty++) {
        for (NSUInteger tx = 0; tx < TS && ok; tx++) {
            for (NSUInteger s = 0; s < SP && ok; s++) {
                double expected = cubeValueAt(tx, ty, s, W, SP);
                double got = tp[(ty * TS + tx) * SP + s];
                if (expected != got) ok = NO;
            }
        }
    }
    PASS(ok, "top-left tile values match cube[0..31, 0..31, *] exactly");

    // ---- tile read: bottom-right (32..63, 32..63) ----
    NSData *tileBR = [TTIOMSImage readTileFromFilePath:path
                                                   atX:32 y:32
                                                 width:TS
                                                height:TS
                                                 error:&err];
    PASS(tileBR != nil, "bottom-right tile reads");
    const double *bp = tileBR.bytes;
    ok = YES;
    for (NSUInteger ty = 0; ty < TS && ok; ty++) {
        for (NSUInteger tx = 0; tx < TS && ok; tx++) {
            for (NSUInteger s = 0; s < SP && ok; s++) {
                double expected = cubeValueAt(32 + tx, 32 + ty, s, W, SP);
                double got = bp[(ty * TS + tx) * SP + s];
                if (expected != got) ok = NO;
            }
        }
    }
    PASS(ok, "bottom-right tile values match cube[32..63, 32..63, *] exactly");

    // ---- non-tile-aligned partial read still works ----
    NSData *partial = [TTIOMSImage readTileFromFilePath:path
                                                    atX:10 y:5
                                                  width:4
                                                 height:3
                                                  error:&err];
    PASS(partial != nil, "non-tile-aligned partial read succeeds");
    PASS(partial.length == 4 * 3 * SP * sizeof(double),
         "partial byte length matches requested dims");

    unlink([path fileSystemRepresentation]);
}
