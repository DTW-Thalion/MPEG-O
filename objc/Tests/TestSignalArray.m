#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/MPGOSignalArray.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOCVParam.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>

static NSString *signalPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_signal_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static MPGOSignalArray *makeSampleArray(void)
{
    const NSUInteger N = 128;
    float *src = malloc(N * sizeof(float));
    for (NSUInteger i = 0; i < N; i++) src[i] = (float)i * 1.5f;
    NSData *buf = [NSData dataWithBytesNoCopy:src length:N*sizeof(float) freeWhenDone:YES];

    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat32
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    MPGOAxisDescriptor *axis =
        [MPGOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"MS:1000040"
                                    valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:200]
                                  samplingMode:MPGOSamplingModeNonUniform];
    return [[MPGOSignalArray alloc] initWithBuffer:buf
                                            length:N
                                          encoding:enc
                                              axis:axis];
}

void testSignalArray(void)
{
    // ---- construction ----
    MPGOSignalArray *a = makeSampleArray();
    PASS(a != nil, "MPGOSignalArray constructible with buffer + encoding + axis");
    PASS(a.length == 128, "length stored");
    PASS(a.buffer.length == 128 * sizeof(float), "buffer size matches");
    PASS(a.encoding.precision == MPGOPrecisionFloat32, "encoding stored");
    PASS([a.axis.name isEqualToString:@"m/z"], "axis stored");

    // ---- CV annotations ----
    MPGOCVParam *p1 = [MPGOCVParam paramWithOntologyRef:@"MS"
                                              accession:@"MS:1000514"
                                                   name:@"m/z array"
                                                  value:nil
                                                   unit:@"MS:1000040"];
    MPGOCVParam *p2 = [MPGOCVParam paramWithOntologyRef:@"MS"
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
    MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
    PASS(f != nil, "create file for round-trip");
    PASS([a writeToGroup:[f rootGroup]
                    name:@"signal"
               chunkSize:32
        compressionLevel:6
                   error:&err],
         "MPGOSignalArray writes to HDF5 group");
    [f close];

    MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
    MPGOSignalArray *b = [MPGOSignalArray readFromGroup:[g rootGroup]
                                                   name:@"signal"
                                                  error:&err];
    PASS(b != nil, "MPGOSignalArray reads from HDF5 group");
    PASS(b.length == a.length, "length round-trips");
    PASS(b.encoding.precision == MPGOPrecisionFloat32, "precision round-trips");
    PASS(b.encoding.compressionAlgorithm == MPGOCompressionZlib, "compression round-trips");
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
    MPGOSignalArray *c = makeSampleArray();
    PASS([c isEqual:makeSampleArray()], "two freshly-built arrays are equal");

    // mutate buffer length: build a smaller one
    float zero = 0.0f;
    NSData *short_ = [NSData dataWithBytes:&zero length:sizeof(float)];
    MPGOSignalArray *small =
        [[MPGOSignalArray alloc] initWithBuffer:short_
                                         length:1
                                       encoding:c.encoding
                                           axis:c.axis];
    PASS(![c isEqual:small], "isEqual: distinguishes buffer length");
}
