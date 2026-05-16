/* tests/linux-modules/src/sync/sync.c
 *
 * The L6 test fixture: exercises mutex + completion. Built the same
 * way as the L1/L3 fixtures (stock kbuild against Linux 6.12 headers);
 * the resulting sync.ko is checked into tests/linux-modules/ for CI
 * consumption.
 *
 * Expected serial output on insmod:
 *     L6: sync primitives round-trip ok
 *     L6: sync.ko module_init
 *
 * Followed by, on rmmod:
 *     L6: sync.ko module_exit
 *
 * The round-trip exercises:
 *   - mutex_init / mutex_lock / mutex_unlock  (sleeping mutex)
 *   - init_completion / complete /
 *     wait_for_completion                     (one-shot wakeup)
 *
 * Because Hamnix is uniprocessor + cooperative at L6, complete() is
 * called BEFORE wait_for_completion() — the wait loop exits on the
 * first iteration. A future fixture that splits the two halves into
 * sibling tasks would exercise the cooperative-yield path inside the
 * L6 shim.
 *
 * Per the L1 shim contract printk is varargs-blind (the shim discards
 * everything past the format string), so this module uses only literal
 * format strings — no %d / %s markers.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/mutex.h>
#include <linux/completion.h>

static struct mutex      l6_mutex;
static struct completion l6_done;

static int __init sync_init(void)
{
    mutex_init(&l6_mutex);
    init_completion(&l6_done);

    mutex_lock(&l6_mutex);
    mutex_unlock(&l6_mutex);

    complete(&l6_done);
    wait_for_completion(&l6_done);

    printk(KERN_INFO "L6: sync primitives round-trip ok\n");
    printk(KERN_INFO "L6: sync.ko module_init\n");
    return 0;
}

static void __exit sync_exit(void)
{
    printk(KERN_INFO "L6: sync.ko module_exit\n");
}

module_init(sync_init);
module_exit(sync_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L6 test fixture - mutex + completion round trip");
MODULE_AUTHOR("Hamnix project");
