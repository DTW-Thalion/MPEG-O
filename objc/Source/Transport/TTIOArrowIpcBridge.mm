/*
 * TTIOArrowIpcBridge.mm
 * TTI-O Objective-C++ glue
 *
 * Bridges TTIOArrowIpcCodec (pure-ObjC) to Apache Arrow C++ (libarrow)
 * for transport-spec v0.11 tabular packet payloads:
 *
 *   - IDENTIFICATIONS_TABLE (packet 0x16)
 *   - QUANTIFICATIONS_TABLE (packet 0x17)
 *   - SUBJECT_METADATA      (packet 0x19, Stage 6)
 *   - SAMPLE_METADATA       (packet 0x1A, Stage 6)
 *
 * Boundary contract
 * -----------------
 * The Objective-C wrapper (TTIOArrowIpcCodec.m) translates ObjC value
 * objects (TTIOIdentification, TTIOQuantification) into a JSON array
 * of dictionaries whose keys exactly match the schema column names,
 * and hands the JSON string to TTIOArrowIpcEncode. Decoding is the
 * inverse: TTIOArrowIpcDecode returns a JSON array string and the
 * wrapper materialises ObjC objects from it. Keeping all C++ code
 * inside this .mm file means callers never need to know about Arrow
 * types and the rest of the ObjC SDK stays in pure Objective-C.
 *
 * Cross-language parity
 * ---------------------
 * Schemas mirror global.thalion.ttio.transport.ArrowIpcCodec (Java) and
 * ttio.transport.arrow_ipc (Python). Payloads are LOGICALLY equivalent
 * across SDKs (same columns, same row order, same values) but not
 * byte-identical -- Arrow IPC flatbuffer framing differs slightly
 * across language bindings.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import <Foundation/Foundation.h>

#include <arrow/api.h>
#include <arrow/io/api.h>
#include <arrow/ipc/api.h>

#include <memory>
#include <string>
#include <vector>

// =====================================================================
//  C entry points consumed by TTIOArrowIpcCodec.m
// =====================================================================

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Encode a JSON-array-of-dicts payload as an Arrow IPC stream.
 *
 * @param schemaName  @"identifications" or @"quantifications".
 * @param rowsJson    UTF-8 JSON array of dicts whose keys match the
 *                    schema's column names.
 * @return NSData of Arrow IPC stream bytes, or nil on error.
 */
NSData * _Nullable TTIOArrowIpcEncode(NSString * _Nonnull schemaName,
                                      NSString * _Nonnull rowsJson);

/**
 * Decode an Arrow IPC stream back to a JSON array of dicts.
 *
 * @param schemaName  @"identifications" or @"quantifications".
 * @param ipc         Arrow IPC stream bytes (may be nil/empty -> @"[]").
 * @return UTF-8 JSON string of an array of dicts, or nil on error.
 */
NSString * _Nullable TTIOArrowIpcDecode(NSString * _Nonnull schemaName,
                                        NSData * _Nullable ipc);

#ifdef __cplusplus
}
#endif

// =====================================================================
//  Internal helpers
// =====================================================================

namespace {

/* Build the IDENTIFICATIONS schema. Cross-language parity with
 * ArrowIpcCodec.java + ttio/transport/arrow_ipc.py. */
std::shared_ptr<arrow::Schema> IdentificationSchema()
{
    return arrow::schema({
        arrow::field("run_name",            arrow::utf8()),
        arrow::field("spectrum_index",      arrow::int32()),
        arrow::field("chemical_entity",     arrow::utf8()),
        arrow::field("confidence_score",    arrow::float64()),
        arrow::field("evidence_chain_json", arrow::utf8()),
    });
}

/* Build the QUANTIFICATIONS schema. */
std::shared_ptr<arrow::Schema> QuantificationSchema()
{
    return arrow::schema({
        arrow::field("chemical_entity",      arrow::utf8()),
        arrow::field("sample_ref",           arrow::utf8()),
        arrow::field("abundance",            arrow::float64()),
        arrow::field("normalization_method", arrow::utf8()),
        arrow::field("unit",                 arrow::utf8()),
    });
}

/* Build the SUBJECT_METADATA (0x19) schema — Stage 6 (transport-spec
 * §4.22). Cross-language parity with Java's
 * ArrowIpcCodec.SUBJECT_SCHEMA + Python's _SUBJECT_SCHEMA. external_id
 * is notNullable; every other field is nullable so the spec §11
 * "empty-string <-> Arrow null" + "sentinel 0 <-> Arrow null"
 * conventions can be encoded directly on the wire. */
std::shared_ptr<arrow::Schema> SubjectSchema()
{
    return arrow::schema({
        arrow::field("external_id",     arrow::utf8(),    /*nullable=*/false),
        arrow::field("project",         arrow::utf8(),    /*nullable=*/true),
        arrow::field("sex",             arrow::utf8(),    /*nullable=*/true),
        arrow::field("birth_year",      arrow::int32(),   /*nullable=*/true),
        arrow::field("attributes_json", arrow::utf8(),    /*nullable=*/true),
    });
}

/* Build the SAMPLE_METADATA (0x1A) schema — Stage 6. sample_id
 * notNullable; collected_at is int64 (not int32). */
std::shared_ptr<arrow::Schema> SampleSchema()
{
    return arrow::schema({
        arrow::field("sample_id",           arrow::utf8(),  /*nullable=*/false),
        arrow::field("subject_external_id", arrow::utf8(),  /*nullable=*/true),
        arrow::field("sample_kind",         arrow::utf8(),  /*nullable=*/true),
        arrow::field("collected_at",        arrow::int64(), /*nullable=*/true),
        arrow::field("attributes_json",     arrow::utf8(),  /*nullable=*/true),
    });
}

std::shared_ptr<arrow::Schema> SchemaForName(NSString *name)
{
    if ([name isEqualToString:@"identifications"]) return IdentificationSchema();
    if ([name isEqualToString:@"quantifications"]) return QuantificationSchema();
    if ([name isEqualToString:@"subjects"])         return SubjectSchema();
    if ([name isEqualToString:@"samples"])          return SampleSchema();
    return nullptr;
}

/* Stage 6 null convention (spec §11): for SUBJECT_METADATA /
 * SAMPLE_METADATA optional string columns, an empty source string
 * encodes to Arrow null. Java's setOptionalString + Python's
 * _str_or_null mirror this. The notNullable primary keys
 * (external_id / sample_id) plus the always-present attributes_json
 * column are exempt — they never null on the wire. */
bool ShouldNullOnEmptyString(NSString *schemaName, NSString *key)
{
    if ([schemaName isEqualToString:@"subjects"]) {
        if ([key isEqualToString:@"external_id"])     return false;
        if ([key isEqualToString:@"attributes_json"]) return false;
        return true;
    }
    if ([schemaName isEqualToString:@"samples"]) {
        if ([key isEqualToString:@"sample_id"])       return false;
        if ([key isEqualToString:@"attributes_json"]) return false;
        return true;
    }
    return false;
}

/* Stage 6 null convention for the optional integer columns
 * (birth_year, collected_at): sentinel 0 encodes to Arrow null.
 * Mirrors Java's `by == 0L` / `ts == 0L` checks and Python's
 * _int_or_null. */
bool ShouldNullOnZero(NSString *schemaName, NSString *key)
{
    if ([schemaName isEqualToString:@"subjects"]
        && [key isEqualToString:@"birth_year"]) return true;
    if ([schemaName isEqualToString:@"samples"]
        && [key isEqualToString:@"collected_at"]) return true;
    return false;
}

/* Pull an NSString from a dict, treating missing / NSNull as empty. */
NSString *PickString(NSDictionary *d, NSString *key)
{
    id v = d[key];
    if (!v || v == [NSNull null]) return @"";
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    return [v description];
}

/* Pull a double, treating missing / NSNull / non-numeric as 0.0. */
double PickDouble(NSDictionary *d, NSString *key)
{
    id v = d[key];
    if (!v || v == [NSNull null]) return 0.0;
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return 0.0;
}

/* Pull an int32, treating missing / NSNull / non-numeric as 0. */
int32_t PickInt32(NSDictionary *d, NSString *key)
{
    id v = d[key];
    if (!v || v == [NSNull null]) return 0;
    if ([v respondsToSelector:@selector(intValue)]) return (int32_t)[v intValue];
    return 0;
}

/* Pull an int64. Stage 6 collected_at uses int64. */
int64_t PickInt64(NSDictionary *d, NSString *key)
{
    id v = d[key];
    if (!v || v == [NSNull null]) return 0;
    if ([v respondsToSelector:@selector(longLongValue)])
        return (int64_t)[v longLongValue];
    if ([v respondsToSelector:@selector(intValue)]) return (int64_t)[v intValue];
    return 0;
}

/* Append a string column value, propagating any builder error. */
arrow::Status AppendUtf8(arrow::StringBuilder *b, NSString *s)
{
    const char *c = s.UTF8String ?: "";
    return b->Append(c, static_cast<int32_t>(strlen(c)));
}

/* Append a typed column from an NSArray of NSDictionary rows. The
 * schemaName + key are used to honour the Stage 6 null conventions
 * (empty-string ↔ null + sentinel-0 ↔ null). For other schemas the
 * conventions are no-ops. */
arrow::Status BuildStringColumn(arrow::StringBuilder *b,
                                NSArray<NSDictionary *> *rows,
                                NSString *schemaName,
                                NSString *key)
{
    const bool nullEmpty = ShouldNullOnEmptyString(schemaName, key);
    for (NSDictionary *r in rows) {
        NSString *s = PickString(r, key);
        if (nullEmpty && s.length == 0) {
            ARROW_RETURN_NOT_OK(b->AppendNull());
        } else {
            ARROW_RETURN_NOT_OK(AppendUtf8(b, s));
        }
    }
    return arrow::Status::OK();
}

arrow::Status BuildInt32Column(arrow::Int32Builder *b,
                               NSArray<NSDictionary *> *rows,
                               NSString *schemaName,
                               NSString *key)
{
    const bool nullZero = ShouldNullOnZero(schemaName, key);
    for (NSDictionary *r in rows) {
        int32_t v = PickInt32(r, key);
        if (nullZero && v == 0) {
            ARROW_RETURN_NOT_OK(b->AppendNull());
        } else {
            ARROW_RETURN_NOT_OK(b->Append(v));
        }
    }
    return arrow::Status::OK();
}

arrow::Status BuildInt64Column(arrow::Int64Builder *b,
                               NSArray<NSDictionary *> *rows,
                               NSString *schemaName,
                               NSString *key)
{
    const bool nullZero = ShouldNullOnZero(schemaName, key);
    for (NSDictionary *r in rows) {
        int64_t v = PickInt64(r, key);
        if (nullZero && v == 0) {
            ARROW_RETURN_NOT_OK(b->AppendNull());
        } else {
            ARROW_RETURN_NOT_OK(b->Append(v));
        }
    }
    return arrow::Status::OK();
}

arrow::Status BuildDoubleColumn(arrow::DoubleBuilder *b,
                                NSArray<NSDictionary *> *rows,
                                NSString *key)
{
    for (NSDictionary *r in rows) {
        ARROW_RETURN_NOT_OK(b->Append(PickDouble(r, key)));
    }
    return arrow::Status::OK();
}

/* Convert a column ptr + row index to an id payload suitable for the
 * NSJSONSerialization round-trip on the decode side. */
id BoxString(const std::shared_ptr<arrow::Array> &a, int64_t i)
{
    if (a->IsNull(i)) return @"";
    auto sa = std::static_pointer_cast<arrow::StringArray>(a);
    std::string s = sa->GetString(i);
    return [[NSString alloc] initWithBytes:s.data()
                                     length:s.size()
                                   encoding:NSUTF8StringEncoding] ?: @"";
}

id BoxInt32(const std::shared_ptr<arrow::Array> &a, int64_t i)
{
    if (a->IsNull(i)) return @(0);
    auto ia = std::static_pointer_cast<arrow::Int32Array>(a);
    return @(ia->Value(i));
}

id BoxInt64(const std::shared_ptr<arrow::Array> &a, int64_t i)
{
    // Stage 6 null convention: null decodes to sentinel 0.
    if (a->IsNull(i)) return @((long long)0);
    auto ia = std::static_pointer_cast<arrow::Int64Array>(a);
    return @((long long)ia->Value(i));
}

id BoxDouble(const std::shared_ptr<arrow::Array> &a, int64_t i)
{
    if (a->IsNull(i)) return @(0.0);
    auto da = std::static_pointer_cast<arrow::DoubleArray>(a);
    return @(da->Value(i));
}

} // namespace

// =====================================================================
//  Encode
// =====================================================================

NSData *TTIOArrowIpcEncode(NSString *schemaName, NSString *rowsJson)
{
    @autoreleasepool {
        auto schema = SchemaForName(schemaName);
        if (!schema) return nil;

        NSData *jsonData = [rowsJson dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) return nil;
        NSError *jsonErr = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:jsonData
                                                    options:0
                                                      error:&jsonErr];
        if (!parsed || ![parsed isKindOfClass:[NSArray class]]) {
            NSLog(@"TTIOArrowIpcEncode: invalid rowsJson: %@", jsonErr);
            return nil;
        }
        NSArray<NSDictionary *> *rows = (NSArray<NSDictionary *> *)parsed;
        const int64_t nRows = static_cast<int64_t>(rows.count);

        arrow::MemoryPool *pool = arrow::default_memory_pool();
        std::vector<std::shared_ptr<arrow::Array>> columns;
        columns.reserve(schema->num_fields());

        for (int idx = 0; idx < schema->num_fields(); ++idx) {
            const auto &field = schema->field(idx);
            NSString *key = [NSString stringWithUTF8String:field->name().c_str()];
            std::shared_ptr<arrow::Array> arr;
            arrow::Status st;

            switch (field->type()->id()) {
                case arrow::Type::STRING: {
                    arrow::StringBuilder b(pool);
                    st = BuildStringColumn(&b, rows, schemaName, key);
                    if (st.ok()) st = b.Finish(&arr);
                    break;
                }
                case arrow::Type::INT32: {
                    arrow::Int32Builder b(pool);
                    st = BuildInt32Column(&b, rows, schemaName, key);
                    if (st.ok()) st = b.Finish(&arr);
                    break;
                }
                case arrow::Type::INT64: {
                    arrow::Int64Builder b(pool);
                    st = BuildInt64Column(&b, rows, schemaName, key);
                    if (st.ok()) st = b.Finish(&arr);
                    break;
                }
                case arrow::Type::DOUBLE: {
                    arrow::DoubleBuilder b(pool);
                    st = BuildDoubleColumn(&b, rows, key);
                    if (st.ok()) st = b.Finish(&arr);
                    break;
                }
                default:
                    NSLog(@"TTIOArrowIpcEncode: unsupported type for %@", key);
                    return nil;
            }
            if (!st.ok()) {
                NSLog(@"TTIOArrowIpcEncode: builder error on %@: %s",
                      key, st.message().c_str());
                return nil;
            }
            columns.push_back(arr);
        }

        auto batch = arrow::RecordBatch::Make(schema, nRows, columns);

        auto sinkRes = arrow::io::BufferOutputStream::Create(0, pool);
        if (!sinkRes.ok()) {
            NSLog(@"TTIOArrowIpcEncode: cannot allocate sink: %s",
                  sinkRes.status().message().c_str());
            return nil;
        }
        auto sink = sinkRes.ValueOrDie();

        auto writerRes = arrow::ipc::MakeStreamWriter(sink.get(), schema);
        if (!writerRes.ok()) {
            NSLog(@"TTIOArrowIpcEncode: writer init failed: %s",
                  writerRes.status().message().c_str());
            return nil;
        }
        auto writer = writerRes.ValueOrDie();
        auto wst = writer->WriteRecordBatch(*batch);
        if (!wst.ok()) {
            NSLog(@"TTIOArrowIpcEncode: WriteRecordBatch failed: %s",
                  wst.message().c_str());
            return nil;
        }
        auto cst = writer->Close();
        if (!cst.ok()) {
            NSLog(@"TTIOArrowIpcEncode: writer close failed: %s",
                  cst.message().c_str());
            return nil;
        }

        auto bufRes = sink->Finish();
        if (!bufRes.ok()) {
            NSLog(@"TTIOArrowIpcEncode: sink finish failed: %s",
                  bufRes.status().message().c_str());
            return nil;
        }
        auto buf = bufRes.ValueOrDie();
        return [NSData dataWithBytes:buf->data()
                              length:static_cast<NSUInteger>(buf->size())];
    }
}

// =====================================================================
//  Decode
// =====================================================================

NSString *TTIOArrowIpcDecode(NSString *schemaName, NSData *ipc)
{
    @autoreleasepool {
        auto schema = SchemaForName(schemaName);
        if (!schema) return nil;
        if (!ipc || ipc.length == 0) return @"[]";

        // arrow::io::BufferReader (libarrow >= 14) takes a
        // std::shared_ptr<arrow::Buffer>; the older raw-pointer ctor
        // was removed. Wrap the NSData bytes in a non-owning Buffer
        // (NSData outlives the synchronous decode call).
        auto buffer = std::make_shared<arrow::Buffer>(
            reinterpret_cast<const uint8_t *>(ipc.bytes),
            static_cast<int64_t>(ipc.length));
        auto bufReader = std::make_shared<arrow::io::BufferReader>(buffer);

        auto readerRes = arrow::ipc::RecordBatchStreamReader::Open(bufReader);
        if (!readerRes.ok()) {
            NSLog(@"TTIOArrowIpcDecode: reader open failed: %s",
                  readerRes.status().message().c_str());
            return nil;
        }
        auto reader = readerRes.ValueOrDie();

        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];

        while (true) {
            std::shared_ptr<arrow::RecordBatch> batch;
            auto rst = reader->ReadNext(&batch);
            if (!rst.ok()) {
                NSLog(@"TTIOArrowIpcDecode: ReadNext failed: %s",
                      rst.message().c_str());
                return nil;
            }
            if (!batch) break;

            const int64_t n = batch->num_rows();
            const auto &actualSchema = batch->schema();

            // Build a column lookup keyed by field name so we tolerate
            // any column ordering in the encoded batch.
            std::vector<std::shared_ptr<arrow::Array>> cols(schema->num_fields());
            for (int idx = 0; idx < schema->num_fields(); ++idx) {
                int actualIdx = actualSchema->GetFieldIndex(schema->field(idx)->name());
                if (actualIdx < 0) {
                    NSLog(@"TTIOArrowIpcDecode: missing column %s",
                          schema->field(idx)->name().c_str());
                    return nil;
                }
                cols[idx] = batch->column(actualIdx);
            }

            for (int64_t r = 0; r < n; ++r) {
                NSMutableDictionary *row =
                    [NSMutableDictionary dictionaryWithCapacity:schema->num_fields()];
                for (int idx = 0; idx < schema->num_fields(); ++idx) {
                    const auto &field = schema->field(idx);
                    NSString *key = [NSString stringWithUTF8String:field->name().c_str()];
                    id boxed = nil;
                    switch (field->type()->id()) {
                        case arrow::Type::STRING: boxed = BoxString(cols[idx], r); break;
                        case arrow::Type::INT32:  boxed = BoxInt32(cols[idx], r);  break;
                        case arrow::Type::INT64:  boxed = BoxInt64(cols[idx], r);  break;
                        case arrow::Type::DOUBLE: boxed = BoxDouble(cols[idx], r); break;
                        default:
                            NSLog(@"TTIOArrowIpcDecode: unsupported type for %@", key);
                            return nil;
                    }
                    row[key] = boxed;
                }
                [out addObject:row];
            }
        }

        NSError *jsonErr = nil;
        NSData *outJson = [NSJSONSerialization dataWithJSONObject:out
                                                          options:0
                                                            error:&jsonErr];
        if (!outJson) {
            NSLog(@"TTIOArrowIpcDecode: JSON serialise failed: %@", jsonErr);
            return nil;
        }
        return [[NSString alloc] initWithData:outJson
                                     encoding:NSUTF8StringEncoding];
    }
}
