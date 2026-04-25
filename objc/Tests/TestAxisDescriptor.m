#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOValueRange.h"
#import "ValueClasses/TTIOEnums.h"

static TTIOAxisDescriptor *roundTripAxis(TTIOAxisDescriptor *a)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:a];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testAxisDescriptor(void)
{
    TTIOValueRange *mzRange =
        [TTIOValueRange rangeWithMinimum:50.0 maximum:2000.0];

    // ---- construction ----
    TTIOAxisDescriptor *axis =
        [TTIOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"MS:1000040"
                                    valueRange:mzRange
                                  samplingMode:TTIOSamplingModeNonUniform];
    PASS(axis != nil, "TTIOAxisDescriptor constructible via class method");
    PASS([axis.name isEqualToString:@"m/z"], "name stored");
    PASS([axis.unit isEqualToString:@"MS:1000040"], "unit stored");
    PASS([axis.valueRange isEqual:mzRange], "valueRange stored");
    PASS(axis.samplingMode == TTIOSamplingModeNonUniform, "samplingMode stored");

    // ---- both sampling modes ----
    TTIOAxisDescriptor *uniform =
        [TTIOAxisDescriptor descriptorWithName:@"time"
                                          unit:@"s"
                                    valueRange:[TTIOValueRange rangeWithMinimum:0 maximum:60]
                                  samplingMode:TTIOSamplingModeUniform];
    PASS(uniform.samplingMode == TTIOSamplingModeUniform, "uniform sampling mode stored");

    // ---- name/unit are copied (defensive copy of NSString) ----
    NSMutableString *mutableName = [NSMutableString stringWithString:@"original"];
    TTIOAxisDescriptor *copyAxis =
        [TTIOAxisDescriptor descriptorWithName:mutableName
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:TTIOSamplingModeUniform];
    [mutableName setString:@"mutated"];
    PASS([copyAxis.name isEqualToString:@"original"],
         "name is defensively copied — caller mutation does not leak in");

    // ---- equality ----
    TTIOAxisDescriptor *a1 =
        [TTIOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:TTIOSamplingModeNonUniform];
    TTIOAxisDescriptor *a2 =
        [TTIOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:[TTIOValueRange rangeWithMinimum:50 maximum:2000]
                                  samplingMode:TTIOSamplingModeNonUniform];
    TTIOAxisDescriptor *diffName =
        [TTIOAxisDescriptor descriptorWithName:@"intensity"
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:TTIOSamplingModeNonUniform];
    TTIOAxisDescriptor *diffUnit =
        [TTIOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"Da"
                                    valueRange:mzRange
                                  samplingMode:TTIOSamplingModeNonUniform];
    TTIOAxisDescriptor *diffRange =
        [TTIOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:[TTIOValueRange rangeWithMinimum:0 maximum:1]
                                  samplingMode:TTIOSamplingModeNonUniform];
    TTIOAxisDescriptor *diffMode =
        [TTIOAxisDescriptor descriptorWithName:@"m/z"
                                          unit:@"u"
                                    valueRange:mzRange
                                  samplingMode:TTIOSamplingModeUniform];

    PASS([a1 isEqual:a1], "isEqual: reflexive");
    PASS([a1 isEqual:a2], "isEqual: equal by value (different range instance)");
    PASS([a1 hash] == [a2 hash], "equal axes hash equal");
    PASS(![a1 isEqual:diffName],  "isEqual: distinguishes name");
    PASS(![a1 isEqual:diffUnit],  "isEqual: distinguishes unit");
    PASS(![a1 isEqual:diffRange], "isEqual: distinguishes valueRange");
    PASS(![a1 isEqual:diffMode],  "isEqual: distinguishes samplingMode");
    PASS(![a1 isEqual:nil], "isEqual: nil → NO");

    // ---- copying (immutable) ----
    TTIOAxisDescriptor *c = [a1 copy];
    PASS(c == a1, "immutable copy returns self");

    // ---- NSCoding round-trip ----
    TTIOAxisDescriptor *decoded = roundTripAxis(a1);
    PASS(decoded != nil, "NSCoding round-trip yields object");
    PASS([decoded isEqual:a1], "decoded equal to original");
    PASS([decoded.name isEqualToString:@"m/z"], "decoded name preserved");
    PASS([decoded.unit isEqualToString:@"u"], "decoded unit preserved");
    PASS([decoded.valueRange isEqual:mzRange], "decoded valueRange preserved");
    PASS(decoded.samplingMode == TTIOSamplingModeNonUniform, "decoded samplingMode preserved");
}
