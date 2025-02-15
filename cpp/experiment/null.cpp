#include <cstddef>
#include <emscripten/bind.h>
// #include <stdint.h>
#include <experiment.h>

static emscripten::val uint8array = emscripten::val::global("Uint8Array");
static emscripten::val console = emscripten::val::global("console");

extern "C" std::size_t
make_table(const emscripten::val& bytes) {
    emscripten::val heap = emscripten::val::global("Module")["HEAPU8"];
    auto byteLen = bytes["byteLength"].as<size_t>();
    auto* data = malloc(byteLen);
    {
        auto buffer = uint8array.new_(
            heap["buffer"], reinterpret_cast<std::size_t>(data), byteLen
        );
        buffer.call<void>("set", uint8array.new_(bytes));
    }

    const auto ptr = reinterpret_cast<std::size_t>(
        table_from_arrow(reinterpret_cast<const std::uint8_t*>(data), byteLen)
    );
    free(data);
    return ptr;
}

extern "C" void
table_print_rows(std::size_t ptr, std::size_t num_rows) {
    print_rows(reinterpret_cast<void*>(ptr), num_rows);
}

EMSCRIPTEN_BINDINGS(experiment) {
    emscripten::function("make_table", &make_table);
    emscripten::function("table_print_rows", &table_print_rows);
    // ---
}
