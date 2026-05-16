/* tests/linux-modules/src/hello/hello.c
 *
 * The L1 test fixture: a minimum-meaningful stock Linux 6.12 module.
 * Built via the parallel Makefile in this directory using stock
 * kbuild against Linux 6.12 headers. The resulting hello.ko is
 * checked into tests/linux-modules/hello.ko so L1 has an exact
 * binary to load on every CI run — no rebuild required.
 *
 * Expected serial output when Hamnix's L1 insmod loads this:
 *     L1: hello.ko module_init
 *
 * Followed by, on rmmod:
 *     L1: hello.ko module_exit
 *
 * The module exercises only printk (the simplest Linux export) and
 * the module_init/exit dispatch (the simplest piece of the ABI).
 * Subsequent L-series milestones add modules that pull in larger
 * surface area (kmalloc at L2, slab caches at L3, etc).
 */

#include <linux/module.h>
#include <linux/kernel.h>

static int __init hello_init(void)
{
    printk(KERN_INFO "L1: hello.ko module_init\n");
    return 0;
}

static void __exit hello_exit(void)
{
    printk(KERN_INFO "L1: hello.ko module_exit\n");
}

module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L1 test fixture — minimum-meaningful module");
MODULE_AUTHOR("Hamnix project");
