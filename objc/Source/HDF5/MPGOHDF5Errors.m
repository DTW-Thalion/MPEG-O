#import "MPGOHDF5Errors.h"

NSString *const MPGOErrorDomain = @"org.mpgo.MPGOErrorDomain";

NSError *MPGOMakeError(MPGOErrorCode code, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    return [NSError errorWithDomain:MPGOErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}
