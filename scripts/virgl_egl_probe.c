/* scripts/virgl_egl_probe.c — GPU track #182 HW-NVIDIA probe (host-side).
 *
 * Directly initializes libvirglrenderer's *own* GL/EGL winsys (the exact code
 * QEMU's virtio-gpu-gl drives) and forces creation of GL context 0 via
 * virgl_renderer_fill_caps. With VIRGL_LOG_LEVEL/VREND_DEBUG set, virglrenderer
 * logs GL_VENDOR/GL_RENDERER/GL_VERSION — so we can see whether virglrenderer
 * lands on the RTX 3090 or on llvmpipe WITHOUT building/booting a whole VM.
 *
 * We try flag combos:
 *   USE_EGL | USE_SURFACELESS  — virgl's surfaceless path (EGL_MESA_platform_
 *                                surfaceless -> Mesa llvmpipe on NVIDIA hosts)
 *   USE_EGL                    — virgl opens a render node / gbm itself
 * Combine with env at launch time (see scripts/test_inguest_gpu_hw.sh):
 *   __EGL_VENDOR_LIBRARY_FILENAMES=10_nvidia.json to exclude Mesa,
 *   VIRGL_* / EGL_PLATFORM to try to force the device platform.
 *
 * Build: cc scripts/virgl_egl_probe.c -o /tmp/virgl_egl_probe -lvirglrenderer
 * The virglrenderer public header is not shipped in this image, so the tiny
 * ABI we need is declared locally (stable since virglrenderer 0.8).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ---- minimal virglrenderer ABI (from virglrenderer.h) ---- */
#define VIRGL_RENDERER_USE_EGL          (1 << 0)
#define VIRGL_RENDERER_THREAD_SYNC      (1 << 1)
#define VIRGL_RENDERER_USE_GLX          (1 << 2)
#define VIRGL_RENDERER_USE_SURFACELESS  (1 << 3)
#define VIRGL_RENDERER_USE_GLES         (1 << 4)

typedef void *virgl_renderer_gl_context;
struct virgl_renderer_gl_ctx_param {
    int version;
    int shared;
    int major_ver;
    int minor_ver;
};
struct virgl_renderer_callbacks {
    int version;
    void (*write_fence)(void *cookie, uint32_t fence);
    virgl_renderer_gl_context (*create_gl_context)(void *cookie, int scanout,
                              struct virgl_renderer_gl_ctx_param *param);
    void (*destroy_gl_context)(void *cookie, virgl_renderer_gl_context ctx);
    int  (*make_current)(void *cookie, int scanout, virgl_renderer_gl_context ctx);
    int  (*get_drm_fd)(void *cookie);
};

extern int  virgl_renderer_init(void *cookie, int flags,
                                struct virgl_renderer_callbacks *cb);
extern void virgl_renderer_cleanup(void *cookie);
extern void virgl_renderer_get_cap_set(uint32_t set, uint32_t *max_ver,
                                       uint32_t *max_size);
extern void virgl_renderer_fill_caps(uint32_t set, uint32_t version, void *caps);

static void cb_write_fence(void *c, uint32_t f) { (void)c; (void)f; }

int main(int argc, char **argv) {
    int flags = VIRGL_RENDERER_USE_EGL;
    if (argc > 1 && strcmp(argv[1], "surfaceless") == 0)
        flags |= VIRGL_RENDERER_USE_SURFACELESS;

    struct virgl_renderer_callbacks cbs;
    memset(&cbs, 0, sizeof cbs);
    cbs.version = 1;
    cbs.write_fence = cb_write_fence;

    fprintf(stderr, "[virgl_egl_probe] virgl_renderer_init(flags=0x%x)\n", flags);
    int r = virgl_renderer_init(NULL, flags, &cbs);
    if (r) {
        fprintf(stderr, "[virgl_egl_probe] virgl_renderer_init FAILED rc=%d\n", r);
        return 3;
    }
    /* Force GL context 0 + caps population -> virglrenderer logs GL strings. */
    uint32_t max_ver = 0, max_size = 0;
    virgl_renderer_get_cap_set(2 /* CAP_SET2 */, &max_ver, &max_size);
    fprintf(stderr, "[virgl_egl_probe] cap_set2 max_ver=%u max_size=%u\n",
            max_ver, max_size);
    if (max_size) {
        void *caps = calloc(1, max_size);
        virgl_renderer_fill_caps(2, max_ver, caps);
        free(caps);
    }
    fprintf(stderr, "[virgl_egl_probe] init OK (see GL_RENDERER line above)\n");
    virgl_renderer_cleanup(NULL);
    return 0;
}
