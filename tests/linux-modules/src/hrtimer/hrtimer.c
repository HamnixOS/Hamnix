/* tests/linux-modules/src/hrtimer/hrtimer.c
 *
 * The L10/M6.2 test fixture: exercises the hrtimer (nanosecond-
 * resolution) family. Built the same way as the L1 hello fixture
 * (stock kbuild against Linux 6.12 headers); resulting hrtimer.ko
 * is checked into tests/linux-modules/ for the regression .ko suite.
 *
 * Expected serial output on insmod:
 *     L10: hrtimer armed
 *     L10: hrtimer.ko module_init
 *     L10: hrtimer fired           (after ~50 ms)
 *
 * Followed by, on rmmod:
 *     L10: hrtimer.ko module_exit
 *
 * The cycle exercises:
 *   - hrtimer_init             (registers the timer in our slot table)
 *   - .function assignment     (Linux convention: write t->function
 *                               between init and start)
 *   - hrtimer_start_range_ns   (arm with ktime_get() + 50 ms)
 *   - the dispatcher           (Hamnix's hrtimer_walk_one_tick fires)
 *   - hrtimer_cancel           (clears the slot on rmmod)
 *
 * Per the L10 shim contract printk is varargs-blind (the shim
 * discards everything past the format string), so this module
 * uses only literal format strings — no %llu markers on ktime
 * values.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/hrtimer.h>
#include <linux/ktime.h>

static struct hrtimer l10_timer;

static enum hrtimer_restart l10_hrtimer_cb(struct hrtimer *t)
{
    printk(KERN_INFO "L10: hrtimer fired\n");
    return HRTIMER_NORESTART;
}

static int __init hrtimer_init_mod(void)
{
    ktime_t now;
    ktime_t deadline;

    hrtimer_init(&l10_timer, CLOCK_MONOTONIC, HRTIMER_MODE_ABS);
    l10_timer.function = l10_hrtimer_cb;

    now = ktime_get();
    deadline = ktime_add_ns(now, 50ULL * 1000ULL * 1000ULL);  /* 50 ms */
    hrtimer_start_range_ns(&l10_timer, deadline, 0, HRTIMER_MODE_ABS);

    printk(KERN_INFO "L10: hrtimer armed\n");
    printk(KERN_INFO "L10: hrtimer.ko module_init\n");
    return 0;
}

static void __exit hrtimer_exit_mod(void)
{
    hrtimer_cancel(&l10_timer);
    printk(KERN_INFO "L10: hrtimer.ko module_exit\n");
}

module_init(hrtimer_init_mod);
module_exit(hrtimer_exit_mod);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L10 test fixture - hrtimer arm/fire/cancel");
MODULE_AUTHOR("Hamnix project");
