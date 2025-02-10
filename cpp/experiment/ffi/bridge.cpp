#include <arrow/io/memory.h>
#include <arrow/ipc/reader.h>
#include <arrow/table.h>
#include <arrow/array/array_binary.h>
#include <arrow/array/array_primitive.h>
#include <iostream>
#include "bridge.h"
#include "arrow/io/buffered.h"

extern "C" {

struct OpaqueArrow {
    std::shared_ptr<arrow::Table> table;
};

dtype
ColumnType(OpaqueArrow* arrow, const char* column) {
    const auto col = arrow->table->GetColumnByName(column);
    if (!col) {}

    std::fputs("Unknown column type", stderr);
    std::abort();
}

void
ReadInto(OpaqueArrow* arrow, const char* column, void* out_data, size_t len) {
    const auto col = arrow->table->GetColumnByName(column);
    if (!col || col->num_chunks() == 0) {
        return;
    }

    uint8_t* dst =
        static_cast<uint8_t*>(out_data); // Output buffer as a byte pointer
    size_t bytes_written = 0;

    for (const auto& array : col->chunks()) {
        if (bytes_written >= len) {
            break; // Stop if we've filled the buffer
        }

        const auto type = array->type_id();

        switch (type) {
            case arrow::Type::INT32: {
                auto int_array =
                    std::static_pointer_cast<arrow::Int32Array>(array);
                size_t copy_size = std::min(
                    (len - bytes_written) / sizeof(int32_t),
                    static_cast<size_t>(int_array->length())
                );
                memcpy(
                    dst + bytes_written,
                    int_array->raw_values(),
                    copy_size * sizeof(int32_t)
                );
                bytes_written += copy_size * sizeof(int32_t);
                break;
            }
            case arrow::Type::FLOAT: {
                auto float_array =
                    std::static_pointer_cast<arrow::FloatArray>(array);
                size_t copy_size = std::min(
                    (len - bytes_written) / sizeof(float),
                    static_cast<size_t>(float_array->length())
                );
                memcpy(
                    dst + bytes_written,
                    float_array->raw_values(),
                    copy_size * sizeof(float)
                );
                bytes_written += copy_size * sizeof(float);
                break;
            }
            case arrow::Type::DOUBLE: {
                auto double_array =
                    std::static_pointer_cast<arrow::DoubleArray>(array);
                size_t copy_size = std::min(
                    (len - bytes_written) / sizeof(double),
                    static_cast<size_t>(double_array->length())
                );
                memcpy(
                    dst + bytes_written,
                    double_array->raw_values(),
                    copy_size * sizeof(double)
                );
                bytes_written += copy_size * sizeof(double);
                break;
            }
            case arrow::Type::STRING: {
                auto string_array =
                    std::static_pointer_cast<arrow::StringArray>(array);
                for (int64_t i = 0; i < string_array->length(); ++i) {
                    if (bytes_written >= len) {
                        break; // Stop if we run out of space
                    }
                    std::string_view str = string_array->GetView(i);
                    size_t copy_size =
                        std::min(len - bytes_written, str.size());
                    memcpy(dst + bytes_written, str.data(), copy_size);
                    bytes_written += copy_size;
                }
                break;
            }
            default:
                std::fputs("Unknown Type", stderr);
                std::abort();
                break;
        }
    }
}

struct OpaqueArrow*
InitArrow(const unsigned char* data, size_t data_len) {
    auto buffer = arrow::io::BufferReader{data, static_cast<int64_t>(data_len)};
    auto reader = arrow::ipc::RecordBatchStreamReader::Open(&buffer);

    if (!reader.ok()) {
        const auto& status = reader.status();
        std::cerr << "ERROR1: " << status.ToString();
    }

    auto table = (*reader)->ToTable();

    if (!table.ok()) {
        const auto& status = table.status();
        std::cerr << "ERROR2: " << status.ToString();
    }

    return new OpaqueArrow{.table = *table};
}

void
FreeArrow(struct OpaqueArrow* out) {
    delete out;
}
}
size_t
TableColumns(struct OpaqueArrow* arrow) {
    return arrow->table->num_columns();
}

size_t
TableSize(struct OpaqueArrow* arrow) {
    return arrow->table->num_rows();
}

void
ReadColumns(struct OpaqueArrow* arrow, struct Field* out) {
    const auto& table = arrow->table;
    const auto& schema = table->schema();
    for (auto i = 0; i < table->num_columns(); i++) {
        const auto& field = schema->field(i);
        enum dtype type;
        switch (field->type()->id()) {
            case arrow::Type::UINT32:
                type = dtype::u32;
                break;
            case arrow::Type::UINT64:
                type = dtype::u64;
                break;
            case arrow::Type::INT32:
                type = dtype::i32;
                break;
            case arrow::Type::DOUBLE:
                type = dtype::f64;
                break;
            case arrow::Type::STRING:
            case arrow::Type::DICTIONARY:
                type = dtype::string;
                break;
            case arrow::Type::DATE32:
                type = dtype::date32;
                break;
            case arrow::Type::DATE64:
                type = dtype::date64;
                break;
            case arrow::Type::INT64:
            case arrow::Type::NA:
            case arrow::Type::BOOL:
            case arrow::Type::UINT8:
            case arrow::Type::INT8:
            case arrow::Type::UINT16:
            case arrow::Type::INT16:
            case arrow::Type::HALF_FLOAT:
            case arrow::Type::FLOAT:
            case arrow::Type::BINARY:
            case arrow::Type::FIXED_SIZE_BINARY:
            case arrow::Type::TIMESTAMP:
            case arrow::Type::TIME32:
            case arrow::Type::TIME64:
            case arrow::Type::INTERVAL_MONTHS:
            case arrow::Type::INTERVAL_DAY_TIME:
            case arrow::Type::DECIMAL128:
            case arrow::Type::DECIMAL256:
            case arrow::Type::LIST:
            case arrow::Type::STRUCT:
            case arrow::Type::SPARSE_UNION:
            case arrow::Type::DENSE_UNION:
            case arrow::Type::MAP:
            case arrow::Type::EXTENSION:
            case arrow::Type::FIXED_SIZE_LIST:
            case arrow::Type::DURATION:
            case arrow::Type::LARGE_STRING:
            case arrow::Type::LARGE_BINARY:
            case arrow::Type::LARGE_LIST:
            case arrow::Type::INTERVAL_MONTH_DAY_NANO:
            case arrow::Type::RUN_END_ENCODED:
            case arrow::Type::STRING_VIEW:
            case arrow::Type::BINARY_VIEW:
            case arrow::Type::LIST_VIEW:
            case arrow::Type::LARGE_LIST_VIEW:
            case arrow::Type::DECIMAL32:
            case arrow::Type::DECIMAL64:
            case arrow::Type::MAX_ID:
                std::cerr << "Unsupported type: " << field->type()->ToString();
                std::abort();
        }
        out[i] = Field{.name = field->name().c_str(), .dtype = type};
    }
}