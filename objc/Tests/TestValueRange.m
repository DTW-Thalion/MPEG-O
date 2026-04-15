#import <Foundation/Foundation.h>
#import "Testing.h"
#import "ValueClasses/MPGOValueRange.h"

static MPGOValueRange *roundTrip(MPGOValueRange *r)
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:r];
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

void testValueRange(void)
{
    // ---- construction ----
    MPGOValueRange *r = [MPGOValueRange rangeWithMinimum:100.0 maximum:2000.0];
    PASS(r != nil, "MPGOValueRange constructible via class method");
    PASS(r.minimum == 100.0, "minimum stored");
    PASS(r.maximum == 2000.0, "maximum stored");
    PASS([r span] == 1900.0, "span = max - min");

    MPGOValueRange *r2 = [[MPGOValueRange alloc] initWithMinimum:-5.0 maximum:5.0];
    PASS(r2 != nil, "MPGOValueRange constructible via designated initializer");
    PASS([r2 span] == 10.0, "span across zero");

    // ---- containsValue ----
    PASS([r containsValue:100.0],  "containsValue: lower bound is inclusive");
    PASS([r containsValue:2000.0], "containsValue: upper bound is inclusive");
    PASS([r containsValue:1050.5], "containsValue: interior point");
    PASS(![r containsValue:99.999], "containsValue: below minimum rejected");
    PASS(![r containsValue:2000.001], "containsValue: above maximum rejected");

    // ---- zero-width range ----
    MPGOValueRange *zero = [MPGOValueRange rangeWithMinimum:42.0 maximum:42.0];
    PASS([zero span] == 0.0, "zero-width span is 0");
    PASS([zero containsValue:42.0], "zero-width range contains its single point");
    PASS(![zero containsValue:42.000001], "zero-width range rejects neighbors");

    // ---- extreme bounds ----
    MPGOValueRange *huge = [MPGOValueRange rangeWithMinimum:-DBL_MAX/2 maximum:DBL_MAX/2];
    PASS([huge containsValue:0.0], "DBL_MAX/2 range contains 0");
    PASS([huge span] > 0, "DBL_MAX/2 span is positive");

    MPGOValueRange *tiny = [MPGOValueRange rangeWithMinimum:0.0 maximum:DBL_MIN];
    PASS([tiny span] == DBL_MIN, "DBL_MIN-wide span survives");

    // ---- equality ----
    MPGOValueRange *a = [MPGOValueRange rangeWithMinimum:1.5 maximum:2.5];
    MPGOValueRange *b = [MPGOValueRange rangeWithMinimum:1.5 maximum:2.5];
    MPGOValueRange *c = [MPGOValueRange rangeWithMinimum:1.5 maximum:2.6];
    PASS([a isEqual:a], "isEqual: reflexive");
    PASS([a isEqual:b] && [b isEqual:a], "isEqual: symmetric for equal values");
    PASS(![a isEqual:c], "isEqual: distinguishes maximum");
    PASS(![a isEqual:nil], "isEqual: nil → NO");
    PASS(![a isEqual:@"not a range"], "isEqual: foreign class → NO");

    // ---- hash ----
    PASS([a hash] == [b hash], "equal objects produce equal hashes");

    // ---- copying (immutable: copy returns self) ----
    MPGOValueRange *copy = [a copy];
    PASS(copy == a, "immutable copy returns self");
    PASS([copy isEqual:a], "copy is equal to original");

    // ---- NSCoding round-trip ----
    MPGOValueRange *decoded = roundTrip(a);
    PASS(decoded != nil, "NSCoding round-trip yields object");
    PASS(decoded != a, "decoded is a fresh instance");
    PASS([decoded isEqual:a], "decoded equal to original");
    PASS(decoded.minimum == 1.5 && decoded.maximum == 2.5, "decoded fields preserved");

    MPGOValueRange *decodedZero = roundTrip(zero);
    PASS([decodedZero isEqual:zero], "zero-width range survives NSCoding");

    MPGOValueRange *decodedHuge = roundTrip(huge);
    PASS(decodedHuge.minimum == -DBL_MAX/2, "DBL_MAX/2 minimum survives NSCoding");
    PASS(decodedHuge.maximum ==  DBL_MAX/2, "DBL_MAX/2 maximum survives NSCoding");
}
