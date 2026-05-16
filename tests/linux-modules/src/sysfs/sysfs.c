/* tests/linux-modules/src/sysfs/sysfs.c
 *
 * The L12 test fixture: exercises the sysfs / kobject registration
 * surface. Built the same way as the L1/L5/L11 fixtures (stock kbuild
 * against Linux 6.12 headers); the resulting sysfs.ko is checked into
 * tests/linux-modules/ for CI consumption.
 *
 * Expected serial output on insmod:
 *     L12: kobject created
 *     L12: sysfs.ko module_init
 *
 * Followed by, on rmmod:
 *     L12: sysfs.ko module_exit
 *
 * The round-trip exercises:
 *   - kobject_create_and_add("hamnix_l12", NULL)
 *   - kobject_put (matching teardown for the implicit refcount=1
 *                  acquired by kobject_create_and_add)
 *
 * Hamnix's L12 shims don't wire a real /sys mountpoint yet — the
 * kobject_create_and_add call just claims a slot in a static table
 * and returns the slot handle widened to pointer width. M7.2's
 * /sys/hamnix/info-style attribute publication is a richer fixture
 * that ships separately; this fixture is the minimum-meaningful
 * "kobject lifecycle works" smoke test.
 *
 * Per the L1 shim contract printk is varargs-blind (the shim discards
 * everything past the format string), so this module uses only literal
 * format strings — no %d / %s markers.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kobject.h>

static struct kobject *l12_kobj;

static int __init sysfs_init(void)
{
    l12_kobj = kobject_create_and_add("hamnix_l12", NULL);
    if (!l12_kobj) {
        printk(KERN_INFO "L12: kobject_create_and_add failed\n");
        return -ENOMEM;
    }
    printk(KERN_INFO "L12: kobject created\n");
    printk(KERN_INFO "L12: sysfs.ko module_init\n");
    return 0;
}

static void __exit sysfs_exit(void)
{
    kobject_put(l12_kobj);
    printk(KERN_INFO "L12: sysfs.ko module_exit\n");
}

module_init(sysfs_init);
module_exit(sysfs_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L12 test fixture - kobject_create_and_add round trip");
MODULE_AUTHOR("Hamnix project");
