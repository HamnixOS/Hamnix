/* scripts/shaderc_compile.c — GLSL -> SPIR-V using the host's libshaderc.
 *
 * THE PRIOR BLOCKER, RESOLVED:
 *   The GPU-raster work stalled on "no SPIR-V toolchain": the `glslc` /
 *   `glslangValidator` BINARIES are not installed on this host. But the
 *   shaderc LIBRARY *is* — libshaderc.so.1 (Debian pkg libshaderc1) ships
 *   glslc's whole compiler as a shared object. No -dev package (no headers)
 *   is installed, so — exactly like scripts/vk_hostgpu_bridge.c does for
 *   libvulkan — we hand-declare the tiny, ABI-stable shaderc C API here and
 *   link the .so directly. That turns the installed library into a working
 *   GLSL->SPIR-V compiler with zero extra packages.
 *
 * BUILD:  gcc scripts/shaderc_compile.c -o build/host/shaderc_compile \
 *              /usr/lib/x86_64-linux-gnu/libshaderc.so.1
 * USAGE:  shaderc_compile IN.{vert,frag,comp} OUT.spv
 *   The shader stage is inferred from IN's extension.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- minimal hand-declared shaderc C ABI (shaderc/shaderc.h subset) ---- */
typedef void* shaderc_compiler_t;
typedef void* shaderc_compilation_result_t;
typedef void* shaderc_compile_options_t;

/* shaderc_shader_kind values we use (from shaderc.h enum). */
#define shaderc_vertex_shader   0
#define shaderc_fragment_shader 1
#define shaderc_compute_shader  2

/* shaderc_compilation_status: 0 == success. */
extern shaderc_compiler_t shaderc_compiler_initialize(void);
extern void shaderc_compiler_release(shaderc_compiler_t);
extern shaderc_compile_options_t shaderc_compile_options_initialize(void);
extern void shaderc_compile_options_set_optimization_level(shaderc_compile_options_t, int);
extern void shaderc_compile_options_release(shaderc_compile_options_t);
extern shaderc_compilation_result_t shaderc_compile_into_spv(
    shaderc_compiler_t, const char* source_text, size_t source_size,
    int shader_kind, const char* input_file_name, const char* entry_point_name,
    shaderc_compile_options_t);
extern int    shaderc_result_get_compilation_status(shaderc_compilation_result_t);
extern size_t shaderc_result_get_length(shaderc_compilation_result_t);
extern const char* shaderc_result_get_bytes(shaderc_compilation_result_t);
extern const char* shaderc_result_get_error_message(shaderc_compilation_result_t);
extern void shaderc_result_release(shaderc_compilation_result_t);

#define shaderc_optimization_level_performance 2

static int kind_from_ext(const char* path) {
    const char* dot = strrchr(path, '.');
    if (!dot) return -1;
    if (!strcmp(dot, ".vert")) return shaderc_vertex_shader;
    if (!strcmp(dot, ".frag")) return shaderc_fragment_shader;
    if (!strcmp(dot, ".comp")) return shaderc_compute_shader;
    return -1;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s IN.{vert,frag,comp} OUT.spv\n", argv[0]);
        return 2;
    }
    int kind = kind_from_ext(argv[1]);
    if (kind < 0) { fprintf(stderr, "shaderc_compile: unknown shader stage for %s\n", argv[1]); return 2; }

    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "shaderc_compile: cannot open %s\n", argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char* src = malloc((size_t)n + 1);
    if (fread(src, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "read error\n"); return 1; }
    src[n] = 0; fclose(f);

    shaderc_compiler_t comp = shaderc_compiler_initialize();
    shaderc_compile_options_t opts = shaderc_compile_options_initialize();
    shaderc_compile_options_set_optimization_level(opts, shaderc_optimization_level_performance);
    shaderc_compilation_result_t res = shaderc_compile_into_spv(
        comp, src, (size_t)n, kind, argv[1], "main", opts);

    int status = shaderc_result_get_compilation_status(res);
    if (status != 0) {
        fprintf(stderr, "shaderc_compile: %s\n", shaderc_result_get_error_message(res));
        shaderc_result_release(res);
        shaderc_compile_options_release(opts);
        shaderc_compiler_release(comp);
        return 1;
    }
    size_t len = shaderc_result_get_length(res);
    const char* bytes = shaderc_result_get_bytes(res);
    FILE* o = fopen(argv[2], "wb");
    if (!o) { fprintf(stderr, "shaderc_compile: cannot write %s\n", argv[2]); return 1; }
    fwrite(bytes, 1, len, o);
    fclose(o);
    fprintf(stderr, "shaderc_compile: %s -> %s (%zu bytes SPIR-V)\n", argv[1], argv[2], len);

    shaderc_result_release(res);
    shaderc_compile_options_release(opts);
    shaderc_compiler_release(comp);
    return 0;
}
