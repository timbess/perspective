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

struct OpaqueArrow;

void ReadInto(
    struct OpaqueArrow* arrow, const char* column, void* out_data, size_t len
);

struct OpaqueArrow* InitArrow(const unsigned char* data, size_t data_len);
void FreeArrow(struct OpaqueArrow* out);

#ifdef __cplusplus
}
#endif