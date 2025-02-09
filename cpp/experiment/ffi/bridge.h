#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum dtype {
    u32,
    u64,
    i32,
    f64,
    string,
};

struct Field {
    const char* name;
    enum dtype dtype;
};

struct OpaqueArrow;

void ReadInto(
    struct OpaqueArrow* arrow, const char* column, void* out_data, size_t len
);

void ReadColumns(struct OpaqueArrow* arrow, struct Field* out);

size_t TableColumns(struct OpaqueArrow* arrow);

size_t TableSize(struct OpaqueArrow* arrow);

struct OpaqueArrow* InitArrow(const unsigned char* data, size_t data_len);
void FreeArrow(struct OpaqueArrow* out);

#ifdef __cplusplus
}
#endif