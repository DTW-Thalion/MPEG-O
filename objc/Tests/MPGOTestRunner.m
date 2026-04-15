#import <Foundation/Foundation.h>
#import "Testing.h"

extern void testValueRange(void);
extern void testEncodingSpec(void);
extern void testAxisDescriptor(void);
extern void testCVParam(void);
extern void testHDF5(void);
extern void testSignalArray(void);
extern void testSpectra(void);

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

        START_SET("MPGOHDF5 wrappers")
            testHDF5();
        END_SET("MPGOHDF5 wrappers")

        START_SET("MPGOSignalArray")
            testSignalArray();
        END_SET("MPGOSignalArray")

        START_SET("Spectrum classes")
            testSpectra();
        END_SET("Spectrum classes")
    }
    return 0;
}
