#include "ffi.h"
#include "perspective/raw_types.h"
#include "types.h"
#include <memory>
#include <perspective/base.h>
#include <perspective/column.h>
#include <chrono>

namespace ffi {

std::unique_ptr<Pool>
mk_pool() {
    return std::unique_ptr<Pool>(new Pool());
}

perspective::t_dtype
convert_to_dtype(DType dtype) {
    return static_cast<perspective::t_dtype>(dtype);
};

DType
get_col_dtype(const Column& col) {
    return static_cast<DType>(col.get_dtype());
}

perspective::t_uindex
get_dtype_size(DType dtype) {
    return perspective::get_dtype_size(convert_to_dtype(dtype));
}

uint32_t
get_col_nth_u32(const Column& col, perspective::t_uindex idx) {
    return *col.get_nth<uint32_t>(idx);
}

uint64_t
get_col_nth_u64(const Column& col, perspective::t_uindex idx) {
    return *col.get_nth<uint64_t>(idx);
}

int32_t
get_col_nth_i32(const Column& col, perspective::t_uindex idx) {
    return *col.get_nth<int32_t>(idx);
}

int64_t
get_col_nth_i64(const Column& col, perspective::t_uindex idx) {
    return *col.get_nth<int64_t>(idx);
}

float
get_col_nth_f32(const Column& col, perspective::t_uindex idx) {
    return *col.get_nth<float>(idx);
}

double
get_col_nth_f64(const Column& col, perspective::t_uindex idx) {
    return *col.get_nth<double>(idx);
}

rust::Vec<rust::String>
get_col_vocab_strings(const Column& col) {
    rust::Vec<rust::String> strings;
    auto mutcol = const_cast<Column*>(&col);
    auto vocab = mutcol->_get_vocab();
    for (perspective::t_uindex i = 0; i < vocab->get_vlenidx(); ++i) {
        strings.push_back(rust::String(vocab->unintern_c(i)));
    }
    return strings;
}

char*
get_col_raw_data(const Column& col) {
    return const_cast<char*>(col.get_nth<char>(0));
}

Status*
get_col_raw_status(const Column& col) {
    auto mutcol = const_cast<Column*>(&col);
    const auto statuses
        = const_cast<perspective::t_status*>(mutcol->get_nth_status(0));
    return reinterpret_cast<Status*>(statuses);
}

static const unsigned char NULLMASK[]
    = {1, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 5, 1 << 6, 1 << 7};

static inline bool
is_not_null(const unsigned char* nullmask, perspective::t_uindex idx) {
    // Example: if usize is 32-bit
    // 0xFFFFFFFF - idx value
    // 0xFFFFFFF1 - Shift off the lower 3 bits.
    // ^ This indexes to the nearest byte since it effectively divides by 8.
    //   but also, you only need 3 bits (dec 0-7) to index into a byte.

    // Then we use the NULLMASK to index into the byte to see if our bit
    // is set. Masking with 0x7 is the same as modding by 8.
    return (nullmask[idx >> 3] & NULLMASK[idx & 7]) != 0;
}

void
fill_column_memcpy(std::shared_ptr<Column> col, const char* ptr,
    const unsigned char* nullmask, perspective::t_uindex start,
    perspective::t_uindex len, std::size_t size) {
    std::memcpy(col->get_nth<char>(start), ptr, len * size);

    perspective::t_status* status
        = const_cast<perspective::t_status*>(col->get_nth_status(start));

    // nullptr means nothing was null ;)
    // unfortunately CXX doesn't support optional yet
    if (nullmask == nullptr) {
        std::memset(status, perspective::t_status::STATUS_VALID, len);
        return;
    }

    for (perspective::t_uindex i = 0; i < len; ++i) {
        if (is_not_null(nullmask, i)) {
            status[i] = perspective::t_status::STATUS_VALID;
        } else {
            status[i] = perspective::t_status::STATUS_INVALID;
        }
    }
}

void
fill_column_date(std::shared_ptr<Column> col, const std::int32_t* ptr,
    const unsigned char* nullmask, perspective::t_uindex start,
    perspective::t_uindex len) {
    auto has_nulls = nullmask != nullptr;
    for (perspective::t_uindex i = 0; i < len; ++i) {
        if (has_nulls && !is_not_null(nullmask, i)) {
            // If set_nth is never called on that cell, the value will be
            // "invalid" or "null".
            continue;
        }
        // Calculate year month and day from
        std::chrono::time_point<std::chrono::system_clock> tp
            = std::chrono::system_clock::from_time_t(
                ptr[i] * 24 * 60 * 60); // days to seconds
        std::time_t time = std::chrono::system_clock::to_time_t(tp);
        std::tm* date = std::localtime(&time);
        perspective::t_date dt(date->tm_year, date->tm_mon, date->tm_mday);
        col->set_nth<perspective::t_date>(start + i, dt);
    }
}

void
fill_column_time(std::shared_ptr<Column> col, const std::int64_t* ptr,
    const unsigned char* nullmask, perspective::t_uindex start,
    perspective::t_uindex len) {
    auto has_nulls = nullmask != nullptr;
    for (perspective::t_uindex i = 0; i < len; ++i) {
        if (has_nulls && !is_not_null(nullmask, i)) {
            // If set_nth is never called on that cell, the value will be
            // "invalid" or "null".
            continue;
        }
        perspective::t_time time(ptr[i]);
        col->set_nth<perspective::t_time>(start + i, time);
    }
}

void
fill_column_dict(std::shared_ptr<Column> col, const char* dict,
    rust::Slice<const std::int32_t> offsets, const std::int32_t* ptr,
    const unsigned char* nullmask, perspective::t_uindex start,
    perspective::t_uindex len) {
    perspective::t_vocab* vocab = col->_get_vocab();
    std::string s;
    for (std::size_t i = 0; i < offsets.size() - 1; ++i) {
        std::size_t es = offsets[i + 1] - offsets[i];
        s.assign(dict + offsets[i], es);
        vocab->get_interned(s);
    }
    // :'(  doesn't work because the source data is i32 and the target is usize
    //
    // fill_column_memcpy(col, reinterpret_cast<const char*>(ptr), nullmask,
    // start,
    //     len, sizeof(perspective::t_uindex));

    auto has_nulls = nullmask != nullptr;
    for (perspective::t_uindex i = 0; i < len; ++i) {
        if (has_nulls && !is_not_null(nullmask, i)) {
            // If set_nth is never called on that cell, the value will be
            // "invalid" or "null".
            continue;
        }
        col->set_nth<perspective::t_uindex>(start + i, ptr[i]);
    }
}

perspective::t_uindex
make_table_port(const Table& table) {
    return const_cast<Table&>(table).make_port();
}

rust::String
pretty_print(const perspective::Table& table, std::size_t num_rows) {
    std::stringstream ss;
    table.get_gnode()->get_table()->pprint(num_rows, &ss);
    std::string s = ss.str();
    return rust::String(s);
}

bool
process_gnode(const GNode& gnode, perspective::t_uindex idx) {
    return const_cast<GNode&>(gnode).process(idx);
}

rust::Vec<rust::String>
get_schema_columns(const Schema& schema) {
    rust::Vec<rust::String> columns;
    for (auto& s : schema.columns()) {
        columns.push_back(rust::String(s));
    }
    return columns;
}

rust::Vec<DType>
get_schema_types(const Schema& schema) {
    rust::Vec<DType> types;
    for (auto& s : schema.types()) {
        types.push_back(static_cast<DType>(s));
    }
    return types;
}

std::unique_ptr<Schema>
get_table_schema(const Table& table) {
    return std::make_unique<Schema>(table.get_schema());
}

std::shared_ptr<Table>
mk_table(rust::Vec<rust::String> column_names_ptr,
    rust::Vec<DType> data_types_ptr, std::uint32_t limit,
    rust::String index_ptr) {

    std::vector<std::string> column_names;
    for (auto s : column_names_ptr) {
        std::string ss(s.begin(), s.end());
        column_names.push_back(ss);
    }
    std::vector<perspective::t_dtype> data_types;
    for (auto s : data_types_ptr) {
        data_types.push_back(convert_to_dtype(s));
    }
    std::string index(index_ptr.begin(), index_ptr.end());

    auto pool = std::make_shared<Pool>();
    auto tbl
        = std::make_shared<Table>(pool, column_names, data_types, limit, index);

    perspective::t_schema schema(column_names, data_types);
    perspective::t_data_table data_table(schema);
    data_table.init();

    auto size = 3;

    data_table.extend(size);

    auto col = data_table.get_column("a");
    col->set_nth<int64_t>(0, 0);
    col->set_nth<int64_t>(1, 1);
    col->set_nth<int64_t>(2, 2);
    col->valid_raw_fill();

    data_table.clone_column("a", "psp_pkey");
    data_table.clone_column("psp_pkey", "psp_okey");

    tbl->init(data_table, size, perspective::t_op::OP_INSERT, 0);

    auto gnode = tbl->get_gnode();
    gnode->process(0);

    return tbl;
}

std::shared_ptr<Table>
mk_table_from_data_table(
    std::unique_ptr<DataTable> data_table, const std::string& index) {
    auto pool = std::make_shared<Pool>();
    auto schema = data_table->get_schema();
    std::shared_ptr<Column> pkey;
    if (schema.has_column("psp_pkey")) {
        pkey = data_table->get_column("psp_pkey");
    } else {
        pkey = data_table->add_column_sptr(
            "psp_pkey", perspective::DTYPE_INT64, true);
        for (std::uint64_t i = 0; i < data_table->size(); ++i) {
            pkey->set_nth<std::uint64_t>(i, i);
        }
    }
    if (!schema.has_column("psp_okey")) {
        data_table->clone_column("psp_pkey", "psp_okey");
    }

    auto columns = data_table->get_schema().columns();
    auto dtypes = data_table->get_schema().types();

    auto tbl = std::make_shared<Table>(
        pool, columns, dtypes, data_table->num_rows(), index);
    tbl->init(
        *data_table, data_table->num_rows(), perspective::t_op::OP_INSERT, 0);
    auto gnode = tbl->get_gnode();
    gnode->process(0);
    return tbl;
}

std::unique_ptr<Schema>
mk_schema(
    rust::Vec<rust::String> column_names_ptr, rust::Vec<DType> data_types_ptr) {
    std::vector<std::string> column_names;
    for (auto s : column_names_ptr) {
        std::string ss(s.begin(), s.end());
        column_names.push_back(ss);
    }
    std::vector<perspective::t_dtype> data_types;
    for (auto s : data_types_ptr) {
        data_types.push_back(convert_to_dtype(s));
    }
    return std::make_unique<Schema>(
        perspective::t_schema(column_names, data_types));
}

std::unique_ptr<DataTable>
mk_data_table(const Schema& schema, perspective::t_uindex capacity) {
    auto data_table = std::make_unique<DataTable>(schema, capacity);
    data_table->init();
    data_table->extend(capacity);
    return data_table;
}

std::unique_ptr<DataTable>
table_extend(std::unique_ptr<DataTable> table, perspective::t_uindex num_rows) {
    table->extend(num_rows);
    return table;
}

} // namespace ffi