/* fcthread_probe.c — Linux-namespace probe for the Firefox/Pango startup hang.
 *
 * Firefox's main thread deadlocks in pangofc-fontmap.c:
 *     while (!pats->match && !pats->fontset)
 *         g_cond_wait (&pats->cond, &pats->mutex);
 * which only terminates if Pango's dedicated "fontconfig" worker thread
 * (fc_thread_func) produces a match.  That worker is the thread that runs
 * FcInit(), so an empty system font set there wedges the main thread forever.
 *
 * This probe answers, with no Gecko in the picture:
 *   (1) can a pthread do directory / file I/O in the Linux namespace?
 *   (2) does FcInit() on the MAIN thread find fonts?
 *   (3) does FcInit() on a WORKER thread find fonts?
 *   (4) how many fds can the process actually open?
 *
 * Build (host):  see tests/u-binary/src/build_fcthread_probe.sh
 * Run (guest):   spawn linux { /fcthread-probe }
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <pthread.h>
#include <dlfcn.h>

static const char *FONTDIR = "/usr/share/fonts";
static const char *FONTTTF = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";

/* Minimal fontconfig ABI — no headers needed. */
typedef struct { int nfont; int sfont; void **fonts; } FcFontSetABI;
typedef int   (*fn_FcInit)(void);
typedef void *(*fn_FcConfigGetCurrent)(void);
typedef void *(*fn_FcConfigGetFonts)(void *, int);
typedef void *(*fn_FcInitLoadConfigAndFonts)(void);

static fn_FcInit                  p_FcInit;
static fn_FcConfigGetCurrent      p_FcConfigGetCurrent;
static fn_FcConfigGetFonts        p_FcConfigGetFonts;
static fn_FcInitLoadConfigAndFonts p_FcInitLoadConfigAndFonts;

#define TAG "[fcprobe] "

static void probe_dir_io(const char *who)
{
    DIR *d = opendir(FONTDIR);
    if (!d) {
        printf(TAG "%s opendir(%s) FAILED errno=%d (%s)\n",
               who, FONTDIR, errno, strerror(errno));
    } else {
        int n = 0;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) n++;
        closedir(d);
        printf(TAG "%s opendir(%s) OK entries=%d\n", who, FONTDIR, n);
    }

    int fd = open(FONTTTF, O_RDONLY);
    if (fd < 0) {
        printf(TAG "%s open(DejaVuSans.ttf) FAILED errno=%d (%s)\n",
               who, errno, strerror(errno));
    } else {
        char buf[16];
        ssize_t r = read(fd, buf, sizeof buf);
        printf(TAG "%s open(DejaVuSans.ttf) OK fd=%d read=%zd\n", who, fd, r);
        close(fd);
    }
    fflush(stdout);
}

static int fc_font_count(void)
{
    void *cfg = p_FcConfigGetCurrent();
    if (!cfg) { printf(TAG "  FcConfigGetCurrent()==NULL\n"); return -1; }
    FcFontSetABI *fs = (FcFontSetABI *) p_FcConfigGetFonts(cfg, 0 /*FcSetSystem*/);
    if (!fs) { printf(TAG "  FcConfigGetFonts(FcSetSystem)==NULL\n"); return -1; }
    return fs->nfont;
}

static void probe_fontconfig(const char *who)
{
    int ok = p_FcInit();
    printf(TAG "%s FcInit() -> %d\n", who, ok);
    int n = fc_font_count();
    printf(TAG "%s system font set nfont=%d  <-- 0 means Pango will deadlock\n", who, n);
    fflush(stdout);
}

static void *worker_dir(void *arg) { (void)arg; probe_dir_io("THREAD"); return NULL; }
static void *worker_fc(void *arg)  { (void)arg; probe_fontconfig("THREAD"); return NULL; }

static void probe_fdlimit(void)
{
    int fds[512], n = 0;
    for (; n < 512; n++) {
        fds[n] = open("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", O_RDONLY);
        if (fds[n] < 0) break;
    }
    printf(TAG "MAIN   opened %d simultaneous fds (errno=%d %s)\n",
           n, errno, strerror(errno));
    for (int i = 0; i < n; i++) close(fds[i]);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    int do_fc = (argc < 2) || strcmp(argv[1], "--io-only");

    printf(TAG "start uid=%d euid=%d\n", (int)getuid(), (int)geteuid());
    fflush(stdout);

    /* (1) raw I/O, main thread then a pthread */
    probe_dir_io("MAIN  ");
    pthread_t t;
    if (pthread_create(&t, NULL, worker_dir, NULL) == 0) pthread_join(t, NULL);
    else printf(TAG "pthread_create(dir) FAILED errno=%d\n", errno);

    /* (4) fd table size */
    probe_fdlimit();

    if (!do_fc) return 0;

    void *h = dlopen("libfontconfig.so.1", RTLD_NOW);
    if (!h) { printf(TAG "dlopen(libfontconfig.so.1) FAILED: %s\n", dlerror()); return 1; }
    p_FcInit             = (fn_FcInit) dlsym(h, "FcInit");
    p_FcConfigGetCurrent = (fn_FcConfigGetCurrent) dlsym(h, "FcConfigGetCurrent");
    p_FcConfigGetFonts   = (fn_FcConfigGetFonts) dlsym(h, "FcConfigGetFonts");
    if (!p_FcInit || !p_FcConfigGetCurrent || !p_FcConfigGetFonts) {
        printf(TAG "dlsym failed\n"); return 1;
    }

    /* (3) FcInit on a WORKER thread first — exactly what Pango does. */
    if (argc > 1 && strcmp(argv[1], "--fc-on-thread") == 0) {
        if (pthread_create(&t, NULL, worker_fc, NULL) == 0) pthread_join(t, NULL);
        else printf(TAG "pthread_create(fc) FAILED errno=%d\n", errno);
    } else {
        /* (2) FcInit on the MAIN thread */
        probe_fontconfig("MAIN  ");
    }

    printf(TAG "done\n");
    fflush(stdout);
    return 0;
}
