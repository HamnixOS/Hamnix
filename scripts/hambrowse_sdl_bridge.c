/* scripts/hambrowse_sdl_bridge.c — the REAL interactive window for hambrowse on
 * the Linux HOST. A thin SDL2 shell around the shared Adder browser engine.
 *
 * WHY A C BRIDGE (mirrors scripts/vk_hostgpu_bridge.c):
 *   The Adder x86_64-linux target links a STATIC, no-libc, no-PIE ELF with raw
 *   syscall wrappers, so it cannot dlopen/link libSDL2. So the browser LOGIC —
 *   parse, layout, paint, click-dispatch, the address bar — lives in the shared
 *   Adder engine (user/hambrowse_sdl_host.ad, the SAME lib/htmlengine + lib/
 *   htmlpage + lib/browserwin the on-device browser uses), and THIS bridge is a
 *   dumb window: it opens a real SDL2 window, pumps OS mouse/keyboard/wheel/
 *   resize events, forwards them to the child over a pipe, reads back rendered
 *   RGB frames, and blits them to the window. No browser logic lives here.
 *
 * NO SDL2 HEADERS are installed on this host (only libSDL2-2.0.so.0), so the
 * minimal, ABI-stable subset we use is hand-declared below with the documented
 * SDL2 struct offsets (stable across SDL2).
 *
 * BUILD:
 *   gcc scripts/hambrowse_sdl_bridge.c -o build/host/hambrowse_sdl_bridge \
 *       /usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0
 *
 * PIPE PROTOCOL (see user/hambrowse_sdl_host.ad). The child emits EXACTLY one
 * frame per command line it receives, so the bridge consumes one frame per
 * command line it sends — kept in lock-step by counting the '\n' we write.
 *   child -> us  : "FRAME <w> <h>\n" + w*h*3 raw RGB bytes
 *   us -> child  : "d <code>\n" | "m <x> <y> <btn> <dz>\n" | "r <w> <h>\n" | "q\n"
 *
 * MODES:
 *   hambrowse_sdl_bridge <child-bin> [PAGE.html]
 *       Interactive: open a window and drive the child from real OS input.
 *   hambrowse_sdl_bridge <child-bin> [PAGE.html] --test SCRIPT OUTDIR
 *       Headless smoke: force SDL's dummy video driver, replay SCRIPT's
 *       synthetic events through the SAME SDL event queue + translation path,
 *       and dump each resulting frame to OUTDIR/frameNNN.ppm. Never blocks on OS
 *       input. Used by scripts/test_hambrowse_sdl_host.sh.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>

/* ---- minimal SDL2 ABI (hand-declared; no headers installed) --------------- */
typedef uint32_t Uint32;
typedef uint16_t Uint16;
typedef int32_t  Sint32;
typedef uint8_t  Uint8;

#define SDL_INIT_VIDEO            0x00000020u
#define SDL_WINDOW_RESIZABLE      0x00000020u
#define SDL_WINDOWPOS_UNDEFINED   0x1FFF0000u
#define SDL_PIXELFORMAT_RGB24     0x17101803u
#define SDL_TEXTUREACCESS_STREAMING 1

/* event types */
#define SDL_QUIT             0x100
#define SDL_WINDOWEVENT      0x200
#define SDL_KEYDOWN          0x300
#define SDL_TEXTINPUT        0x303
#define SDL_MOUSEMOTION      0x400
#define SDL_MOUSEBUTTONDOWN  0x401
#define SDL_MOUSEBUTTONUP    0x402
#define SDL_MOUSEWHEEL       0x403

#define SDL_WINDOWEVENT_RESIZED       5
#define SDL_WINDOWEVENT_SIZE_CHANGED  6

/* keycodes */
#define SDLK_RETURN     0x0D
#define SDLK_ESCAPE     0x1B
#define SDLK_BACKSPACE  0x08
#define SDLK_DELETE     0x7F
#define SDLK_RIGHT      0x4000004F
#define SDLK_LEFT       0x40000050
#define SDLK_DOWN       0x40000051
#define SDLK_UP         0x40000052
#define SDLK_HOME       0x4000004A
#define SDLK_END        0x4000004D

/* key modifiers */
#define KMOD_CTRL       0x00C0   /* LCTRL | RCTRL */

/* SDL_Event is a 56-byte union; we over-allocate and access by documented
 * offset so we never depend on the full struct definitions. */
typedef union { Uint8 raw[128]; Uint32 type; } SDL_Event;

/* field offsets (bytes) into SDL_Event for the events we use (SDL2-stable) */
#define OFF_WINDOW_EVENT   12   /* Uint8  window.event   */
#define OFF_WINDOW_DATA1   16   /* Sint32 window.data1   */
#define OFF_WINDOW_DATA2   20   /* Sint32 window.data2   */
#define OFF_KEY_SYM        20   /* Sint32 key.keysym.sym */
#define OFF_KEY_MOD        24   /* Uint16 key.keysym.mod */
#define OFF_TEXT_TEXT      12   /* char   text.text[32]  */
#define OFF_BUTTON_BUTTON  16   /* Uint8  button.button  */
#define OFF_BUTTON_X       20   /* Sint32 button.x       */
#define OFF_BUTTON_Y       24   /* Sint32 button.y       */
#define OFF_MOTION_X       20   /* Sint32 motion.x       */
#define OFF_MOTION_Y       24   /* Sint32 motion.y       */
#define OFF_WHEEL_Y        20   /* Sint32 wheel.y        */

extern int    SDL_Init(Uint32);
extern void   SDL_Quit(void);
extern const char *SDL_GetError(void);
extern void  *SDL_CreateWindow(const char*, int, int, int, int, Uint32);
extern void   SDL_DestroyWindow(void*);
extern void  *SDL_CreateRenderer(void*, int, Uint32);
extern void  *SDL_CreateTexture(void*, Uint32, int, int, int);
extern void   SDL_DestroyTexture(void*);
extern int    SDL_UpdateTexture(void*, const void*, const void*, int);
extern int    SDL_RenderClear(void*);
extern int    SDL_RenderCopy(void*, void*, const void*, const void*);
extern void   SDL_RenderPresent(void*);
extern int    SDL_WaitEvent(SDL_Event*);
extern int    SDL_PollEvent(SDL_Event*);
extern int    SDL_PushEvent(SDL_Event*);
extern void   SDL_StartTextInput(void);

/* ---- child process plumbing ---------------------------------------------- */
static int   g_to_child   = -1;   /* we write commands here (child stdin)  */
static int   g_from_child = -1;   /* we read frames here    (child stdout) */
static pid_t g_child_pid  = -1;
static int   g_lines_sent = 0;    /* command lines sent since last reset    */

static int spawn_child(const char *bin, const char *page) {
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) < 0 || pipe(out_pipe) < 0) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        dup2(in_pipe[0], 0);
        dup2(out_pipe[1], 1);
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        if (page) execl(bin, bin, page, (char*)NULL);
        else      execl(bin, bin, (char*)NULL);
        _exit(127);
    }
    close(in_pipe[0]); close(out_pipe[1]);
    g_to_child = in_pipe[1];
    g_from_child = out_pipe[0];
    g_child_pid = pid;
    return 0;
}

static int read_full(int fd, void *buf, size_t n) {
    size_t got = 0; char *p = (char*)buf;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

/* Read one "FRAME w h\n" header + w*h*3 body from the child. */
static int read_frame(int *w, int *h, unsigned char **buf, size_t *cap) {
    char hdr[64]; int hi = 0;
    for (;;) {
        char c; ssize_t r = read(g_from_child, &c, 1);
        if (r <= 0) return -1;
        if (c == '\n') break;
        if (hi < (int)sizeof(hdr) - 1) hdr[hi++] = c;
    }
    hdr[hi] = 0;
    if (strncmp(hdr, "FRAME ", 6) != 0) return -1;
    if (sscanf(hdr + 6, "%d %d", w, h) != 2) return -1;
    size_t need = (size_t)(*w) * (size_t)(*h) * 3u;
    if (need > *cap) { *buf = realloc(*buf, need); *cap = need; }
    if (read_full(g_from_child, *buf, need) < 0) return -1;
    return 0;
}

/* Send one or more newline-terminated command lines to the child, counting the
 * lines so the caller knows how many frames to consume. */
static void send_cmd(const char *s) {
    if (g_to_child < 0) return;
    ssize_t w = write(g_to_child, s, strlen(s));
    (void)w;
    for (const char *p = s; *p; p++) if (*p == '\n') g_lines_sent++;
}

/* ---- SDL event -> child command translation (shared by both modes) -------- */
static int g_last_x = 0, g_last_y = 0;

/* Translate one SDL event into zero or more child command lines (each command
 * makes the child emit exactly one frame — tracked via g_lines_sent). Returns 1
 * if a quit was requested. */
static int translate_event(SDL_Event *e) {
    char line[80];
    Uint32 t = e->type;
    if (t == SDL_QUIT) { send_cmd("q\n"); return 1; }
    if (t == SDL_WINDOWEVENT) {
        Uint8 we = *(Uint8*)(e->raw + OFF_WINDOW_EVENT);
        if (we == SDL_WINDOWEVENT_SIZE_CHANGED || we == SDL_WINDOWEVENT_RESIZED) {
            int nw = *(Sint32*)(e->raw + OFF_WINDOW_DATA1);
            int nh = *(Sint32*)(e->raw + OFF_WINDOW_DATA2);
            snprintf(line, sizeof line, "r %d %d\n", nw, nh);
            send_cmd(line);
        }
        return 0;
    }
    if (t == SDL_MOUSEBUTTONDOWN || t == SDL_MOUSEBUTTONUP) {
        Sint32 x = *(Sint32*)(e->raw + OFF_BUTTON_X);
        Sint32 y = *(Sint32*)(e->raw + OFF_BUTTON_Y);
        Uint8  b = *(Uint8*) (e->raw + OFF_BUTTON_BUTTON);
        int down = (t == SDL_MOUSEBUTTONDOWN) ? 1 : 0;
        int btn = (b == 1 && down) ? 1 : 0;   /* bit0 = left held */
        g_last_x = x; g_last_y = y;
        snprintf(line, sizeof line, "m %d %d %d 0\n", x, y, btn);
        send_cmd(line);
        return 0;
    }
    if (t == SDL_MOUSEMOTION) {
        g_last_x = *(Sint32*)(e->raw + OFF_MOTION_X);
        g_last_y = *(Sint32*)(e->raw + OFF_MOTION_Y);
        return 0;  /* motion alone drives nothing; no command, no frame */
    }
    if (t == SDL_MOUSEWHEEL) {
        Sint32 dy = *(Sint32*)(e->raw + OFF_WHEEL_Y);
        if (dy != 0) {
            snprintf(line, sizeof line, "m %d %d 0 %d\n", g_last_x, g_last_y, dy);
            send_cmd(line);
        }
        return 0;
    }
    if (t == SDL_TEXTINPUT) {
        const char *txt = (const char*)(e->raw + OFF_TEXT_TEXT);
        for (int i = 0; txt[i] && i < 32; i++) {
            unsigned char c = (unsigned char)txt[i];
            if (c >= 32 && c < 127) {
                snprintf(line, sizeof line, "d %d\n", (int)c);
                send_cmd(line);
            }
        }
        return 0;
    }
    if (t == SDL_KEYDOWN) {
        Sint32 sym = *(Sint32*)(e->raw + OFF_KEY_SYM);
        Uint16 mod = *(Uint16*)(e->raw + OFF_KEY_MOD);
        /* Ctrl+letter -> the device's raw control byte (Ctrl-A=1, Ctrl-C=3,...).
         * The address bar uses Ctrl-A (select all). Ctrl+letters never produce
         * SDL_TEXTINPUT, so there is no double-insert. */
        if ((mod & KMOD_CTRL) && sym >= 'a' && sym <= 'z') {
            snprintf(line, sizeof line, "d %d\n", (int)(sym - 'a' + 1));
            send_cmd(line);
            return 0;
        }
        int fin = 0;
        switch (sym) {
            case SDLK_RETURN:    send_cmd("d 13\n");  return 0;
            case SDLK_BACKSPACE: send_cmd("d 8\n");   return 0;
            case SDLK_ESCAPE:    send_cmd("d 27\n");  return 0;
            case SDLK_DELETE:    send_cmd("d 27\nd 91\nd 51\nd 126\n"); return 0;
            case SDLK_LEFT:  fin = 'D'; break;
            case SDLK_RIGHT: fin = 'C'; break;
            case SDLK_UP:    fin = 'A'; break;
            case SDLK_DOWN:  fin = 'B'; break;
            case SDLK_HOME:  fin = 'H'; break;
            case SDLK_END:   fin = 'F'; break;
            default: return 0;   /* printable keys arrive via SDL_TEXTINPUT */
        }
        snprintf(line, sizeof line, "d 27\nd 91\nd %d\n", fin);
        send_cmd(line);
        return 0;
    }
    return 0;
}

/* ---- window state --------------------------------------------------------- */
static void *g_win = NULL, *g_ren = NULL, *g_tex = NULL;
static int   g_tex_w = 0, g_tex_h = 0;
static int   g_frame_no = 0;
static const char *g_outdir = NULL;

static void ensure_texture(int w, int h) {
    if (g_tex && g_tex_w == w && g_tex_h == h) return;
    if (g_tex) SDL_DestroyTexture(g_tex);
    g_tex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_RGB24,
                              SDL_TEXTUREACCESS_STREAMING, w, h);
    g_tex_w = w; g_tex_h = h;
}

static void present(int w, int h, unsigned char *rgb) {
    if (!g_ren) return;
    ensure_texture(w, h);
    if (!g_tex) return;
    SDL_UpdateTexture(g_tex, NULL, rgb, w * 3);
    SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, NULL);
    SDL_RenderPresent(g_ren);
}

static void write_ppm(const char *path, int w, int h, unsigned char *rgb) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    fwrite(rgb, 1, (size_t)w * h * 3, f);
    fclose(f);
}

/* Read one frame from the child and present/save it. Returns 0 ok, -1 on EOF. */
static int consume_frame(unsigned char **buf, size_t *cap) {
    int w, h;
    if (read_frame(&w, &h, buf, cap) < 0) return -1;
    if (g_outdir) {
        char path[512];
        snprintf(path, sizeof path, "%s/frame%03d.ppm", g_outdir, g_frame_no);
        write_ppm(path, w, h, *buf);
    }
    present(w, h, *buf);
    g_frame_no++;
    return 0;
}

/* Handle one SDL event: translate to child commands, then consume exactly one
 * frame per command line sent. Returns 1 to keep running, 0 to stop. */
static int handle_event(SDL_Event *e, unsigned char **buf, size_t *cap) {
    g_lines_sent = 0;
    int quit = translate_event(e);
    for (int k = 0; k < g_lines_sent; k++)
        if (consume_frame(buf, cap) < 0) return 0;
    return quit ? 0 : 1;
}

/* Push a synthetic SDL event for --test mode (mod only used for KEYDOWN). */
static void push_event(Uint32 type, int a, int b, Uint8 btn, Uint16 mod,
                       const char *text) {
    SDL_Event e;
    memset(&e, 0, sizeof e);
    e.type = type;
    if (type == SDL_MOUSEBUTTONDOWN || type == SDL_MOUSEBUTTONUP) {
        *(Uint8*) (e.raw + OFF_BUTTON_BUTTON) = btn ? btn : 1;
        *(Sint32*)(e.raw + OFF_BUTTON_X) = a;
        *(Sint32*)(e.raw + OFF_BUTTON_Y) = b;
    } else if (type == SDL_MOUSEWHEEL) {
        *(Sint32*)(e.raw + OFF_WHEEL_Y) = a;
    } else if (type == SDL_KEYDOWN) {
        *(Sint32*)(e.raw + OFF_KEY_SYM) = a;
        *(Uint16*)(e.raw + OFF_KEY_MOD) = mod;
    } else if (type == SDL_TEXTINPUT) {
        strncpy((char*)(e.raw + OFF_TEXT_TEXT), text ? text : "", 31);
    } else if (type == SDL_WINDOWEVENT) {
        *(Uint8*) (e.raw + OFF_WINDOW_EVENT) = SDL_WINDOWEVENT_SIZE_CHANGED;
        *(Sint32*)(e.raw + OFF_WINDOW_DATA1) = a;
        *(Sint32*)(e.raw + OFF_WINDOW_DATA2) = b;
    }
    SDL_PushEvent(&e);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <child-bin> [PAGE.html] [--test SCRIPT OUTDIR]\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);   /* a closed child pipe must not kill us */
    const char *child_bin = argv[1];
    const char *page = NULL, *script = NULL;
    int test_mode = 0;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--test") == 0 && i + 2 < argc) {
            test_mode = 1; script = argv[i+1]; g_outdir = argv[i+2]; i += 2;
        } else if (!page) {
            page = argv[i];
        }
    }

    if (test_mode) setenv("SDL_VIDEODRIVER", "dummy", 0);

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    if (spawn_child(child_bin, page) < 0) {
        fprintf(stderr, "cannot spawn child %s\n", child_bin);
        SDL_Quit(); return 1;
    }

    unsigned char *buf = NULL; size_t cap = 0;
    int w = 0, h = 0;
    if (read_frame(&w, &h, &buf, &cap) < 0) {
        fprintf(stderr, "child produced no initial frame\n");
        SDL_Quit(); return 1;
    }

    g_win = SDL_CreateWindow("hambrowse (Linux host)",
                             SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                             w, h, SDL_WINDOW_RESIZABLE);
    if (!g_win) fprintf(stderr, "SDL_CreateWindow: %s (continuing)\n", SDL_GetError());
    if (g_win) {
        g_ren = SDL_CreateRenderer(g_win, -1, 0);
        if (!g_ren) fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
    }
    SDL_StartTextInput();

    /* present the initial frame */
    if (g_outdir) {
        char path[512];
        snprintf(path, sizeof path, "%s/frame%03d.ppm", g_outdir, g_frame_no);
        write_ppm(path, w, h, buf);
    }
    present(w, h, buf);
    g_frame_no++;

    if (test_mode) {
        FILE *sf = fopen(script, "r");
        if (!sf) fprintf(stderr, "cannot open script %s\n", script);
        char ln[256];
        int running = 1;
        while (running && sf && fgets(ln, sizeof ln, sf)) {
            char verb[32]; int a = 0, b = 0; char rest[200];
            if (sscanf(ln, "%31s", verb) != 1) continue;
            if (strcmp(verb, "click") == 0 && sscanf(ln, "%*s %d %d", &a, &b) == 2) {
                push_event(SDL_MOUSEBUTTONDOWN, a, b, 1, 0, NULL);
                push_event(SDL_MOUSEBUTTONUP,   a, b, 1, 0, NULL);
            } else if (strcmp(verb, "wheel") == 0 && sscanf(ln, "%*s %d", &a) == 1) {
                push_event(SDL_MOUSEWHEEL, a, 0, 0, 0, NULL);
            } else if (strcmp(verb, "key") == 0 && sscanf(ln, "%*s %d", &a) == 1) {
                push_event(SDL_KEYDOWN, a, 0, 0, 0, NULL);
            } else if (strcmp(verb, "ctrlkey") == 0 && sscanf(ln, "%*s %d", &a) == 1) {
                push_event(SDL_KEYDOWN, a, 0, 0, KMOD_CTRL, NULL);
            } else if (strcmp(verb, "text") == 0 && sscanf(ln, "%*s %199[^\n]", rest) == 1) {
                /* Real typing delivers one SDL_TEXTINPUT per keystroke; push one
                 * per character (SDL_TextInputEvent.text is only 32 bytes, so a
                 * single event cannot carry a long path). */
                char one[2] = {0, 0};
                for (int c = 0; rest[c]; c++) {
                    one[0] = rest[c];
                    push_event(SDL_TEXTINPUT, 0, 0, 0, 0, one);
                }
            } else if (strcmp(verb, "resize") == 0 && sscanf(ln, "%*s %d %d", &a, &b) == 2) {
                push_event(SDL_WINDOWEVENT, a, b, 0, 0, NULL);
            } else if (strcmp(verb, "quit") == 0) {
                push_event(SDL_QUIT, 0, 0, 0, 0, NULL);
            } else {
                continue;
            }
            /* Drain the queue through the SAME per-event path as interactive. */
            SDL_Event e;
            while (SDL_PollEvent(&e)) {
                if (handle_event(&e, &buf, &cap) == 0) { running = 0; break; }
            }
        }
        if (sf) fclose(sf);
        send_cmd("q\n");
        close(g_to_child); g_to_child = -1;
        int st; waitpid(g_child_pid, &st, 0);
        free(buf);
        SDL_Quit();
        fprintf(stderr, "[bridge] test done: %d frames -> %s\n", g_frame_no, g_outdir);
        return 0;
    }

    /* ---- interactive: real OS input --------------------------------------- */
    SDL_Event e;
    int running = 1;
    while (running && SDL_WaitEvent(&e)) {
        if (handle_event(&e, &buf, &cap) == 0) running = 0;
    }

    send_cmd("q\n");
    if (g_to_child >= 0) close(g_to_child);
    int st; waitpid(g_child_pid, &st, 0);
    free(buf);
    if (g_tex) SDL_DestroyTexture(g_tex);
    if (g_win) SDL_DestroyWindow(g_win);
    SDL_Quit();
    return 0;
}
