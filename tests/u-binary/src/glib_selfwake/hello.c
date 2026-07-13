/* tests/u-binary/src/glib_selfwake/hello.c
 *
 * Minimal, FAST reproducer of GLib's GMainContext cross-thread SELF-WAKE —
 * the exact intra-process wakeup pattern every GTK/GLib/Wayland app (foot,
 * Firefox/Gecko, gtk3 apps) relies on to hand work from a worker thread to
 * the main loop. It is far smaller than `foot` and needs no rootfs / GL / 6G
 * boot: pure pthreads + raw syscalls, embedded straight into the initramfs.
 *
 * WHY THIS FIXTURE EXISTS
 * -----------------------
 * The Firefox/Wayland deep-track repeatedly hypothesised a "GLib cross-thread
 * self-wake gap": a worker thread signals the main-context wakeup fd (on modern
 * glibc an eventfd, historically a self-pipe) but the main thread, parked in
 * poll()/ppoll()/epoll_wait() on that fd, never wakes → the main loop never
 * advances (Firefox never issues get_xdg_surface). foot + Qt already map
 * windows, which argues the primitive works — but no gate PROVED the
 * cross-thread edge. epoll_rdy only tests a SINGLE-THREADED write-then-wait.
 *
 * WHAT GLib ACTUALLY DOES (mirrored here)
 * ---------------------------------------
 *   g_wakeup_new()      -> eventfd(0, EFD_CLOEXEC|EFD_NONBLOCK)   (pipe fallback)
 *   g_main loop wait    -> g_poll() == poll()/ppoll() with the wakeup fd in the
 *                          set requesting G_IO_IN (POLLIN)
 *   g_main_context_wakeup() from a worker -> g_wakeup_signal() -> write(fd, 1)
 *   g_main_context_check -> drains the wakeup fd (read)
 *
 * So the load-bearing edge is: THREAD A parks in poll/ppoll/epoll_wait on a fd;
 * THREAD B writes that fd; A must observe POLLIN and return. We exercise all
 * four transport x wait-syscall combinations GLib/Gecko use, cross-thread,
 * over many rounds, with idle sibling threads so the thread group is large
 * (Firefox-class), and a hard watchdog so a genuine lost wakeup prints a FAIL
 * verdict rather than hanging QEMU silently.
 *
 * Cases (each = ROUNDS cross-thread wakeups):
 *   1. eventfd  + poll(-1)        GLib default main-loop wait
 *   2. eventfd  + ppoll(NULL)     glibc g_poll's preferred syscall
 *   3. eventfd  + epoll_wait(-1)  Gecko libevent / base::MessagePump
 *   4. self-pipe + poll(-1)       GLib's pre-eventfd fallback
 *
 * Raw inline syscalls (no musl poll/epoll wrappers) so the test pins the
 * kernel Linux-ABI edge, not libc. pthreads are real (CLONE_VM|CLONE_THREAD),
 * so the wakeup genuinely crosses threads sharing one address space — exactly
 * GLib's situation. The single signaler always writes 8 bytes (a valid eventfd
 * counter add; harmless as pipe payload), so one thread serves all 4 cases.
 *
 * Prints exactly one verdict line: "U-GLIBWAKE: PASS" / "U-GLIBWAKE: FAIL ...".
 */
#include <pthread.h>
#include <stdint.h>

#define SYS_read           0
#define SYS_write          1
#define SYS_close          3
#define SYS_poll           7
#define SYS_nanosleep      35
#define SYS_exit_group     231
#define SYS_epoll_wait     232
#define SYS_epoll_ctl      233
#define SYS_ppoll          271
#define SYS_eventfd2       290
#define SYS_epoll_create1  291
#define SYS_pipe2          293

#define POLLIN            0x001
#define EPOLLIN           0x001
#define EPOLL_CTL_ADD     1
#define EFD_NONBLOCK      0x800

#define N_IDLE     10          /* idle siblings -> big thread group (Firefox-y) */
#define ROUNDS     120         /* cross-thread wakeups per case                 */
#define WATCHDOG_S 40

struct pollfd { int fd; short events; short revents; };
struct epoll_event { uint32_t events; uint64_t data; } __attribute__((packed));
struct kts { long tv_sec; long tv_nsec; };

static long sys1(long nr, long a) {
    long rc; __asm__ volatile("syscall":"=a"(rc):"0"(nr),"D"(a):"rcx","r11","memory");
    return rc;
}
static long sys2(long nr, long a, long b) {
    long rc; __asm__ volatile("syscall":"=a"(rc):"0"(nr),"D"(a),"S"(b):"rcx","r11","memory");
    return rc;
}
static long sys3(long nr, long a, long b, long c) {
    long rc; __asm__ volatile("syscall":"=a"(rc):"0"(nr),"D"(a),"S"(b),"d"(c):"rcx","r11","memory");
    return rc;
}
static long sys4(long nr, long a, long b, long c, long d) {
    long rc; register long r10 __asm__("r10")=d;
    __asm__ volatile("syscall":"=a"(rc):"0"(nr),"D"(a),"S"(b),"d"(c),"r"(r10):"rcx","r11","memory");
    return rc;
}
static long sys6(long nr, long a, long b, long c, long d, long e, long f) {
    long rc; register long r10 __asm__("r10")=d, r8 __asm__("r8")=e, r9 __asm__("r9")=f;
    __asm__ volatile("syscall":"=a"(rc)
        :"0"(nr),"D"(a),"S"(b),"d"(c),"r"(r10),"r"(r8),"r"(r9):"rcx","r11","memory");
    return rc;
}

static unsigned long slen(const char *s){ unsigned long n=0; while(s[n]) n++; return n; }
static void puts_s(const char *s){ sys3(SYS_write,1,(long)s,(long)slen(s)); }
static void puts_d(const char *pfx,long v){
    char b[96]; unsigned long p=0; const char *s=pfx; while(*s) b[p++]=*s++;
    char t[24]; int ti=0,neg=0; unsigned long u;
    if(v<0){neg=1;u=(unsigned long)(-v);} else u=(unsigned long)v;
    if(!u) t[ti++]='0'; while(u){t[ti++]=(char)('0'+(u%10));u/=10;}
    if(neg) b[p++]='-'; while(ti) b[p++]=t[--ti]; b[p++]='\n';
    sys3(SYS_write,1,(long)b,(long)p);
}
static void msleep(long ms){ struct kts ts; ts.tv_sec=ms/1000; ts.tv_nsec=(ms%1000)*1000000L; sys2(SYS_nanosleep,(long)&ts,0); }

/* ---- shared state between main (parker) and the signaler thread ---- */
static volatile int  g_wakefd   = -1;    /* fd the signaler writes to     */
static volatile long g_arm      = 0;     /* main bumps this to arm a round */
static volatile long g_done     = 0;     /* signaler echoes the round done */
static volatile int  g_finished = 0;
static volatile long g_round    = 0;
static volatile long g_case     = 0;

/* Mirrors g_main_context_wakeup() from a GLib worker: spin-wait (NO extra
 * futex — we test the fd edge, not another futex) for main to arm a round,
 * delay briefly so main is genuinely PARKED inside poll/ppoll/epoll_wait,
 * then write 8 bytes to the current wakeup fd (eventfd counter += 1; for a
 * pipe it is just 8 bytes of payload). */
static void *signaler(void *arg) {
    (void)arg;
    long seen = 0;
    uint64_t one = 1;
    for (;;) {
        while (__atomic_load_n(&g_arm, __ATOMIC_ACQUIRE) == seen) {
            if (__atomic_load_n(&g_finished, __ATOMIC_ACQUIRE)) return NULL;
            msleep(1);
        }
        seen = __atomic_load_n(&g_arm, __ATOMIC_ACQUIRE);
        msleep(3);                              /* let main reach the park */
        sys3(SYS_write, __atomic_load_n(&g_wakefd, __ATOMIC_ACQUIRE),
             (long)&one, 8);
        __atomic_store_n(&g_done, seen, __ATOMIC_RELEASE);
    }
}

static void *idle(void *arg){ (void)arg; while(!__atomic_load_n(&g_finished,__ATOMIC_ACQUIRE)) msleep(20); return NULL; }

static void *watchdog(void *arg){
    (void)arg; int i;
    for(i=0;i<WATCHDOG_S*10;i++){
        if(__atomic_load_n(&g_finished,__ATOMIC_ACQUIRE)) return NULL;
        msleep(100);
    }
    if(!__atomic_load_n(&g_finished,__ATOMIC_ACQUIRE)){
        puts_d("U-GLIBWAKE: FAIL cross-thread self-wake LOST — stalled in case ",
               __atomic_load_n(&g_case,__ATOMIC_ACQUIRE));
        puts_d("U-GLIBWAKE:   at round ", __atomic_load_n(&g_round,__ATOMIC_ACQUIRE));
        sys1(SYS_exit_group,1);
    }
    return NULL;
}

/* Block in poll(-1) until the wakefd is POLLIN. Returns 1 on a real wake,
 * 0 if the (watchdog-bounded) retry budget is blown (treated as lost). */
static int wait_poll(int fd){
    struct pollfd pfd; long budget = WATCHDOG_S*1000/2;   /* ~half watchdog */
    while (budget > 0){
        pfd.fd=fd; pfd.events=POLLIN; pfd.revents=0;
        long n = sys3(SYS_poll,(long)&pfd,1,-1);           /* -1 == block */
        if (n>0 && (pfd.revents & POLLIN)) return 1;
        budget -= 20;                                      /* spurious 0 -> retry */
    }
    return 0;
}
static int wait_ppoll(int fd){
    struct pollfd pfd; long budget = WATCHDOG_S*1000/2;
    while (budget > 0){
        pfd.fd=fd; pfd.events=POLLIN; pfd.revents=0;
        long n = sys6(SYS_ppoll,(long)&pfd,1,0,0,0,0);     /* NULL tmo == block */
        if (n>0 && (pfd.revents & POLLIN)) return 1;
        budget -= 20;
    }
    return 0;
}
static int wait_epoll(int epfd){
    struct epoll_event ev; long budget = WATCHDOG_S*1000/2;
    while (budget > 0){
        ev.events=0; ev.data=0;
        long n = sys4(SYS_epoll_wait,epfd,(long)&ev,1,-1); /* -1 == block */
        if (n>0 && (ev.events & EPOLLIN)) return 1;
        budget -= 20;
    }
    return 0;
}
static void drain_eventfd(int fd){ uint64_t v; sys3(SYS_read,fd,(long)&v,8); }
static void drain_pipe(int fd){ char b[64]; sys3(SYS_read,fd,(long)b,64); }

static int run_case(long cnum, const char *name, int wakefd, int drainfd,
                    int is_pipe, int (*waitfn)(int), int waitarg){
    __atomic_store_n(&g_case, cnum, __ATOMIC_RELEASE);
    __atomic_store_n(&g_wakefd, wakefd, __ATOMIC_RELEASE);
    long r;
    for (r=0; r<ROUNDS; r++){
        long target = __atomic_load_n(&g_arm, __ATOMIC_ACQUIRE) + 1;
        __atomic_store_n(&g_round, r, __ATOMIC_RELEASE);
        __atomic_store_n(&g_arm, target, __ATOMIC_RELEASE);   /* arm signaler */
        if (!waitfn(waitarg)){                                /* PARK on the fd */
            puts_d("U-GLIBWAKE: FAIL lost wake in case ", cnum);
            return 0;
        }
        if (is_pipe) drain_pipe(drainfd); else drain_eventfd(drainfd);
        while (__atomic_load_n(&g_done,__ATOMIC_ACQUIRE) != target) msleep(1);
    }
    puts_d(name, ROUNDS);
    return 1;
}

int main(void){
    pthread_t sig, wd, idles[N_IDLE];
    long i;

    puts_s("U-GLIBWAKE: start (GLib GMainContext cross-thread self-wake repro)\n");

    if (pthread_create(&wd, NULL, watchdog, NULL) != 0){ puts_s("U-GLIBWAKE: FAIL spawn watchdog\n"); return 1; }
    for (i=0;i<N_IDLE;i++)
        if (pthread_create(&idles[i], NULL, idle, NULL) != 0){ puts_s("U-GLIBWAKE: FAIL spawn idle\n"); return 1; }

    /* ---- transports ---- */
    long efd = sys2(SYS_eventfd2, 0, EFD_NONBLOCK);
    if (efd < 0){ puts_d("U-GLIBWAKE: FAIL eventfd2 rc=", efd); return 1; }
    long epfd = sys1(SYS_epoll_create1, 0);
    if (epfd < 0){ puts_d("U-GLIBWAKE: FAIL epoll_create1 rc=", epfd); return 1; }
    struct epoll_event reg; reg.events=EPOLLIN; reg.data=0x7a;
    if (sys4(SYS_epoll_ctl, epfd, EPOLL_CTL_ADD, efd, (long)&reg) < 0){
        puts_s("U-GLIBWAKE: FAIL epoll_ctl ADD\n"); return 1; }

    int pfds[2]; long pr = sys2(SYS_pipe2, (long)pfds, 0);  /* pipe2 writes int[2] */
    if (pr < 0){ puts_d("U-GLIBWAKE: FAIL pipe2 rc=", pr); return 1; }
    int pipe_rd=pfds[0], pipe_wr=pfds[1];

    if (pthread_create(&sig, NULL, signaler, NULL) != 0){ puts_s("U-GLIBWAKE: FAIL spawn signaler\n"); return 1; }

    if (!run_case(1,"U-GLIBWAKE: case1 eventfd+poll   ok rounds=", (int)efd,(int)efd,0,wait_poll,(int)efd)) return 1;
    if (!run_case(2,"U-GLIBWAKE: case2 eventfd+ppoll  ok rounds=", (int)efd,(int)efd,0,wait_ppoll,(int)efd)) return 1;
    if (!run_case(3,"U-GLIBWAKE: case3 eventfd+epoll  ok rounds=", (int)efd,(int)efd,0,wait_epoll,(int)epfd)) return 1;
    if (!run_case(4,"U-GLIBWAKE: case4 pipe+poll      ok rounds=", pipe_wr,pipe_rd,1,wait_poll,pipe_rd)) return 1;

    __atomic_store_n(&g_finished, 1, __ATOMIC_SEQ_CST);
    sys1(SYS_close, efd); sys1(SYS_close, epfd);
    sys1(SYS_close, pipe_rd); sys1(SYS_close, pipe_wr);

    puts_s("U-GLIBWAKE: all 4 cross-thread self-wake transports delivered\n");
    puts_s("U-GLIBWAKE: PASS\n");
    return 0;
}
