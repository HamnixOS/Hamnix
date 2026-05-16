/* tests/linux-modules/src/chrdev/chrdev.c
 *
 * L4 test fixture: a minimum-meaningful character-device registration.
 * Mirrors the structure of the L1 hello/, L2 slab/, L3 proc/ fixtures —
 * built via stock kbuild against Linux 6.12, then copied up to
 * tests/linux-modules/chrdev.ko for the M5.1 regression slot.
 *
 * Expected serial output when Hamnix's L1 loader insmods this:
 *     L4: chrdev registered
 *     L4: chrdev unregistered                  (on rmmod)
 *
 * What this exercises:
 *   - register_chrdev(0, ...)            → auto-major path
 *   - unregister_chrdev(major, ...)      → cleanup symmetry
 *   - struct file_operations definition  → opaque-blob handling in api_chrdev.ad
 *
 * What this DOESN'T exercise yet (deferred to later L milestones):
 *   - cdev_init / cdev_add / cdev_del    → covered by their own fixture
 *     when VFS wiring lands and the dispatch table actually serves
 *     open()/read() through the registered fops.
 *   - alloc_chrdev_region / unregister_chrdev_region
 *   - read/write/open/release callbacks  → fops here is empty; the
 *     dispatch table isn't consulted yet at L4.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>

#define HAMNIX_L4_NAME "hamnix_l4"

static int hamnix_l4_major;

static const struct file_operations fops = {
    .owner = THIS_MODULE,
    /* No callbacks: L4 doesn't dispatch through this table yet. */
};

static int __init chrdev_init(void)
{
    hamnix_l4_major = register_chrdev(0, HAMNIX_L4_NAME, &fops);
    if (hamnix_l4_major < 0) {
        printk(KERN_ERR "L4: register_chrdev failed\n");
        return hamnix_l4_major;
    }
    printk(KERN_INFO "L4: chrdev registered\n");
    return 0;
}

static void __exit chrdev_exit(void)
{
    unregister_chrdev(hamnix_l4_major, HAMNIX_L4_NAME);
    printk(KERN_INFO "L4: chrdev unregistered\n");
}

module_init(chrdev_init);
module_exit(chrdev_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L4 test fixture — register_chrdev round-trip");
MODULE_AUTHOR("Hamnix project");
