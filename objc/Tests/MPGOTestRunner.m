#import <Foundation/Foundation.h>
#import "Testing.h"

extern void testValueRange(void);
extern void testEncodingSpec(void);
extern void testAxisDescriptor(void);
extern void testCVParam(void);

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        START_SET("MPGOValueRange")
            testValueRange();
        END_SET("MPGOValueRange")

        START_SET("MPGOEncodingSpec")
            testEncodingSpec();
        END_SET("MPGOEncodingSpec")

        START_SET("MPGOAxisDescriptor")
            testAxisDescriptor();
        END_SET("MPGOAxisDescriptor")

        START_SET("MPGOCVParam")
            testCVParam();
        END_SET("MPGOCVParam")
    }
    return 0;
}
