#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOCVParam.h"
#import "ValueClasses/TTIOEnums.h"
#import <unistd.h>

static NSString *signalPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_signal_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOSignalArray *makeSampleArray(void)
{
    const NSUInteger N = 128;
    float *src = malloc(N * sizeof(float));
    for (NSUInteger i = 0; i < N; i++) src[i] = (float)i * 1.5f;
    NSData *buf = [NSData dataWithBytesNoCopy:src length:N*sizeof(float) freeWhenDone:YES];

    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat32
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    TTIOAxisDescriptor *axis =
        [TTIOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"MS:1000040"
                                    valueRange:[TTIOValueRange rangeWithMinimum:0 maximum:200]
                                  samplingMode:TTIOSamplingModeNonUniform];
    return [[TTIOSignalArray alloc] initWithBuffer:buf
                                            length:N
                                          encoding:enc
                                              axis:axis];
}

void testSignalArray(void)
{
    // ---- construction ----
    TTIOSignalArray *a = makeSampleArray();
    PASS(a != nil, "TTIOSignalArray constructible with buffer + encoding + axis");
    PASS(a.length == 128, "length stored");
    PASS(a.buffer.length == 128 * sizeof(float), "buffer size matches");
    PASS(a.encoding.precision == TTIOPrecisionFloat32, "encoding stored");
    PASS([a.axis.name isEqualToString:@"m/z"], "axis stored");

    // ---- CV annotations ----
    TTIOCVParam *p1 = [TTIOCVParam paramWithOntologyRef:@"MS"
                                              accession:@"MS:1000514"
                                                   name:@"m/z array"
                                                  value:nil
                                                   unit:@"MS:1000040"];
    TTIOCVParam *p2 = [TTIOCVParam paramWithOntologyRef:@"MS"
                                              accession:@"MS:1000523"
                                                   name:@"64-bit float"
                                                  value:nil
                                                   unit:nil];
    [a addCVParam:p1];
    [a addCVParam:p2];
    PASS([a allCVParams].count == 2, "two CV params attached");
    PASS([a hasCVParamWithAccession:@"MS:1000514"], "hasCVParamWithAccession: positive");
    PASS(![a hasCVParamWithAccession:@"MS:9999999"], "hasCVParamWithAccession: negative");
    PASS([[a cvParamsForOntologyRef:@"MS"] count] == 2, "filter by ontology");

    // ---- HDF5 round-trip ----
    NSString *path = signalPath(@"roundtrip");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
    PASS(f != nil, "create file for round-trip");
    PASS([a writeToGroup:[f rootGroup]
                    name:@"signal"
               chunkSize:32
        compressionLevel:6
                   error:&err],
         "TTIOSignalArray writes to HDF5 group");
    [f close];

    TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
    TTIOSignalArray *b = [TTIOSignalArray readFromGroup:[g rootGroup]
                                                   name:@"signal"
                                                  error:&err];
    PASS(b != nil, "TTIOSignalArray reads from HDF5 group");
    PASS(b.length == a.length, "length round-trips");
    PASS(b.encoding.precision == TTIOPrecisionFloat32, "precision round-trips");
    PASS(b.encoding.compressionAlgorithm == TTIOCompressionZlib, "compression round-trips");
    PASS([b.axis.name isEqualToString:@"m/z"], "axis name round-trips");
    PASS(b.axis.valueRange.maximum == 200.0, "axis range max round-trips");
    PASS([b.buffer isEqualToData:a.buffer], "buffer bytes round-trip exactly");
    PASS([b allCVParams].count == 2, "CV params count round-trips");
    PASS([b hasCVParamWithAccession:@"MS:1000514"], "first CVParam survives round-trip");
    PASS([b hasCVParamWithAccession:@"MS:1000523"], "second CVParam survives round-trip");
    PASS([b isEqual:a], "round-tripped signal array isEqual: original");

    [g close];
    unlink([path fileSystemRepresentation]);

    // ---- equality discrimination ----
    TTIOSignalArray *c = makeSampleArray();
    PASS([c isEqual:makeSampleArray()], "two freshly-built arrays are equal");

    // mutate buffer length: build a smaller one
    float zero = 0.0f;
    NSData *short_ = [NSData dataWithBytes:&zero length:sizeof(float)];
    TTIOSignalArray *small =
        [[TTIOSignalArray alloc] initWithBuffer:short_
                                         length:1
                                       encoding:c.encoding
                                           axis:c.axis];
    PASS(![c isEqual:small], "isEqual: distinguishes buffer length");
}
