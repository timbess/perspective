#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum dtype {
    u32,
    u64,
    i32,
    i64,
    f64,
    date32,
    date64,
    string,
};

struct Field {
    const char* name;
    enum dtype dtype;
};

struct DictColumnChunk {
    const unsigned char* dict_values;
    const int* offsets;
    size_t dict_size;
    void* indices;
    size_t indices_size;
    enum dtype index_type;
};

struct OpaqueArrow;

void ReadInto(
    struct OpaqueArrow* arrow, const char* column, void* out_data, size_t len
);

void ReadColumns(struct OpaqueArrow* arrow, struct Field* out);

int NumChunks(struct OpaqueArrow* arrow, const char* column_name);

void GetDictColumn(
    struct OpaqueArrow* arrow,
    const char* column_name,
    struct DictColumnChunk* out_dict_column_chunks
); // Modified to take a pointer to DictColumn

size_t TableColumns(struct OpaqueArrow* arrow);

size_t TableSize(struct OpaqueArrow* arrow);

struct OpaqueArrow* InitArrow(const unsigned char* data, size_t data_len);
void FreeArrow(struct OpaqueArrow* out);

#ifdef __cplusplus
}
#endif