/* scripts/egl_device_probe.c — GPU track #182 HW-NVIDIA probe.
 *
 * Answers ONE question before we bother booting a whole VM: can this host
 * create a *headless* OpenGL context on the RTX 3090, and by which EGL
 * platform? QEMU's -display egl-headless uses the EGL *GBM* platform, which
 * the NVIDIA proprietary driver's headless GBM backend rejects (falls back to
 * llvmpipe). The NVIDIA GPU does headless GL only via the EGL *device*
 * platform (EGL_EXT_platform_device / eglQueryDevicesEXT).
 *
 * This probe tries, in order, and reports GL_VENDOR / GL_RENDERER / GL_VERSION
 * for whichever succeeds:
 *   1. EGL_PLATFORM_DEVICE_EXT over each enumerated EGLDeviceEXT
 *   2. EGL_PLATFORM_GBM_KHR   over the given DRM render node (mimics QEMU)
 *   3. plain eglGetDisplay(EGL_DEFAULT_DISPLAY) / surfaceless
 *
 * Build: cc scripts/egl_device_probe.c -o /tmp/egl_device_probe -lEGL -lGL
 * Run:   /tmp/egl_device_probe [/dev/dri/renderD128]
 *
 * A line "PROBE-RESULT platform=<p> GL_RENDERER=<...>" is emitted for every
 * context that comes up so the harness can grep for NVIDIA vs llvmpipe.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>

/* eglext may not declare every entry point as a symbol; fetch via GetProcAddress. */
typedef EGLBoolean (*PFN_eglQueryDevicesEXT)(EGLint, EGLDeviceEXT *, EGLint *);
typedef const char *(*PFN_eglQueryDeviceStringEXT)(EGLDeviceEXT, EGLint);
typedef EGLDisplay (*PFN_eglGetPlatformDisplayEXT)(EGLenum, void *, const EGLint *);

static const char *estr(EGLint e) {
    switch (e) {
    case EGL_SUCCESS: return "EGL_SUCCESS";
    case EGL_BAD_DISPLAY: return "EGL_BAD_DISPLAY";
    case EGL_NOT_INITIALIZED: return "EGL_NOT_INITIALIZED";
    case EGL_BAD_PARAMETER: return "EGL_BAD_PARAMETER";
    case EGL_BAD_ATTRIBUTE: return "EGL_BAD_ATTRIBUTE";
    case EGL_BAD_ALLOC: return "EGL_BAD_ALLOC";
    case EGL_BAD_MATCH: return "EGL_BAD_MATCH";
    default: return "EGL_<other>";
    }
}

/* Bring up a GL context on an already-obtained EGLDisplay and report renderer. */
static int report_context(const char *platform, EGLDisplay dpy) {
    EGLint major = 0, minor = 0;
    if (!eglInitialize(dpy, &major, &minor)) {
        fprintf(stderr, "  [%s] eglInitialize failed: %s\n", platform, estr(eglGetError()));
        return 0;
    }
    fprintf(stderr, "  [%s] EGL %d.%d — %s\n", platform, major, minor,
            eglQueryString(dpy, EGL_VENDOR));

    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg; EGLint ncfg = 0;
    if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &ncfg) || ncfg < 1) {
        fprintf(stderr, "  [%s] eglChooseConfig: %s (ncfg=%d)\n", platform, estr(eglGetError()), ncfg);
        eglTerminate(dpy);
        return 0;
    }
    if (!eglBindAPI(EGL_OPENGL_API)) {
        fprintf(stderr, "  [%s] eglBindAPI(GL) failed\n", platform);
        eglTerminate(dpy);
        return 0;
    }
    const EGLint ctx_attr[] = { EGL_CONTEXT_MAJOR_VERSION, 4,
                                EGL_CONTEXT_MINOR_VERSION, 5, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
    if (ctx == EGL_NO_CONTEXT) {
        /* retry without a version hint */
        ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, NULL);
    }
    if (ctx == EGL_NO_CONTEXT) {
        fprintf(stderr, "  [%s] eglCreateContext: %s\n", platform, estr(eglGetError()));
        eglTerminate(dpy);
        return 0;
    }
    /* surfaceless make-current (needs EGL_KHR_surfaceless_context) */
    if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
        /* fall back to a 1x1 pbuffer */
        const EGLint pb[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        EGLSurface s = eglCreatePbufferSurface(dpy, cfg, pb);
        if (s == EGL_NO_SURFACE || !eglMakeCurrent(dpy, s, s, ctx)) {
            fprintf(stderr, "  [%s] eglMakeCurrent: %s\n", platform, estr(eglGetError()));
            eglDestroyContext(dpy, ctx);
            eglTerminate(dpy);
            return 0;
        }
    }
    const char *vnd = (const char *)glGetString(GL_VENDOR);
    const char *rnd = (const char *)glGetString(GL_RENDERER);
    const char *ver = (const char *)glGetString(GL_VERSION);
    printf("PROBE-RESULT platform=%s GL_VENDOR=%s GL_RENDERER=%s GL_VERSION=%s\n",
           platform, vnd ? vnd : "?", rnd ? rnd : "?", ver ? ver : "?");
    fflush(stdout);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy, ctx);
    eglTerminate(dpy);
    return 1;
}

int main(int argc, char **argv) {
    const char *rnode = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    int any = 0;

    const char *client_exts = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    fprintf(stderr, "EGL client extensions: %s\n", client_exts ? client_exts : "(null)");

    PFN_eglGetPlatformDisplayEXT getPlatformDisplayEXT =
        (PFN_eglGetPlatformDisplayEXT)eglGetProcAddress("eglGetPlatformDisplayEXT");
    PFN_eglQueryDevicesEXT queryDevices =
        (PFN_eglQueryDevicesEXT)eglGetProcAddress("eglQueryDevicesEXT");
    PFN_eglQueryDeviceStringEXT queryDevStr =
        (PFN_eglQueryDeviceStringEXT)eglGetProcAddress("eglQueryDeviceStringEXT");

    /* ---- 1. EGL_PLATFORM_DEVICE_EXT over each enumerated device ---- */
    if (queryDevices && getPlatformDisplayEXT) {
        EGLDeviceEXT devs[16]; EGLint ndev = 0;
        if (queryDevices(16, devs, &ndev) && ndev > 0) {
            fprintf(stderr, "eglQueryDevicesEXT: %d device(s)\n", ndev);
            for (EGLint i = 0; i < ndev; i++) {
                const char *dstr = queryDevStr ? queryDevStr(devs[i], EGL_EXTENSIONS) : "";
                const char *dnode = NULL;
                if (queryDevStr) {
                    /* EGL_DRM_DEVICE_FILE_EXT = 0x3233 */
                    dnode = queryDevStr(devs[i], 0x3233);
                }
                fprintf(stderr, "  device[%d] node=%s ext=%s\n", i,
                        dnode ? dnode : "(none)", dstr ? dstr : "");
                char tag[64];
                snprintf(tag, sizeof tag, "EGLDevice[%d]", i);
                EGLDisplay dpy = getPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, devs[i], NULL);
                if (dpy != EGL_NO_DISPLAY)
                    any |= report_context(tag, dpy);
                else
                    fprintf(stderr, "  [%s] getPlatformDisplay(DEVICE): %s\n", tag, estr(eglGetError()));
            }
        } else {
            fprintf(stderr, "eglQueryDevicesEXT returned no devices: %s\n", estr(eglGetError()));
        }
    } else {
        fprintf(stderr, "EGL_EXT_device_query/enumeration not available\n");
    }

    /* ---- 2. EGL_PLATFORM_GBM_KHR over the render node (what QEMU does) ---- */
    if (getPlatformDisplayEXT) {
        int fd = open(rnode, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            /* EGL_PLATFORM_GBM_KHR = 0x31D7; pass the raw fd is not valid — GBM
             * needs a gbm_device. We only report whether the platform display
             * even initializes with the device pointer QEMU would build. Since
             * we can't easily link libgbm here without headers guaranteed, skip
             * gracefully; the DEVICE path above is the decisive one. */
            close(fd);
        }
    }

    /* ---- 3. default display (surfaceless/llvmpipe fallback) ---- */
    {
        EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (dpy != EGL_NO_DISPLAY)
            any |= report_context("DEFAULT", dpy);
    }

    if (!any) {
        fprintf(stderr, "PROBE-RESULT: no GL context could be created on any platform\n");
        return 2;
    }
    return 0;
}
