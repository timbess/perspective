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