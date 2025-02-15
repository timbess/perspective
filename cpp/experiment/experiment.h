#include "zig.h"
zig_extern void *table_from_arrow(uint8_t const *const a0, uintptr_t const a1);
zig_extern void print_rows(void *const a0, uintptr_t const a1);
zig_extern void GetDictColumn(void *const a0, uint8_t const *const a1, struct struct_DictColumnChunk__2852 *const a2);
zig_extern void *InitArrow(uint8_t const *const a0, uintptr_t const a1);
zig_extern uintptr_t TableColumns(void *const a0);
zig_extern void ReadColumns(void *const a0, struct struct_Field__2086 *const a1);
zig_extern uintptr_t TableSize(void *const a0);
zig_extern int NumChunks(void *const a0, uint8_t const *const a1);
zig_extern void ReadInto(void *const a0, uint8_t const *const a1, void *const a2, uintptr_t const a3);
zig_extern void FreeArrow(void *const a0);
zig_extern void *malloc(uintptr_t const a0);
zig_extern void free(void *const a0);
zig_extern void zig_e___stack_chk_fail(void);
zig_extern void emscripten_console_error(uint8_t const *const a0);
zig_extern void emscripten_console_log(uint8_t const *const a0);
zig_extern zig_noreturn void emscripten_force_exit(int const a0);
zig_extern intptr_t write(int32_t const a0, uint8_t const *const a1, uintptr_t const a2);
zig_extern int *zig_e___errno_location(void);
