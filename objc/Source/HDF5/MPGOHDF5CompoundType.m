#import "MPGOHDF5CompoundType.h"

@implementation MPGOHDF5CompoundType
{
    hid_t               _typeId;
    size_t              _totalSize;
    NSMutableArray     *_auxTypeIds;   // NSNumbers of child hid_ts to close
    BOOL                _closed;
}

- (instancetype)initWithSize:(size_t)totalSize
{
    self = [super init];
    if (self) {
        _totalSize  = totalSize;
        _typeId     = H5Tcreate(H5T_COMPOUND, totalSize);
        _auxTypeIds = [NSMutableArray array];
        _closed     = NO;
        if (_typeId < 0) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

- (BOOL)addField:(NSString *)name
            type:(hid_t)type
          offset:(size_t)offset
{
    if (_closed || _typeId < 0) return NO;
    herr_t rc = H5Tinsert(_typeId, [name UTF8String], offset, type);
    return rc >= 0;
}

- (BOOL)addVariableLengthStringFieldNamed:(NSString *)name
                                  atOffset:(size_t)offset
{
    if (_closed || _typeId < 0) return NO;
    hid_t strType = H5Tcopy(H5T_C_S1);
    if (strType < 0) return NO;
    if (H5Tset_size(strType, H5T_VARIABLE) < 0) {
        H5Tclose(strType);
        return NO;
    }
    if (H5Tinsert(_typeId, [name UTF8String], offset, strType) < 0) {
        H5Tclose(strType);
        return NO;
    }
    [_auxTypeIds addObject:@(strType)];
    return YES;
}

- (hid_t)typeId    { return _typeId; }
- (size_t)totalSize { return _totalSize; }

- (void)close
{
    if (_closed) return;
    for (NSNumber *n in _auxTypeIds) {
        hid_t t = (hid_t)n.longLongValue;
        if (t >= 0) H5Tclose(t);
    }
    [_auxTypeIds removeAllObjects];
    if (_typeId >= 0) {
        H5Tclose(_typeId);
        _typeId = -1;
    }
    _closed = YES;
}

@end
