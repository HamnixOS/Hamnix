/* tests/linux-modules/src/slab/slab.c
 *
 * The L3 test fixture: exercises the kmem_cache_* family. Built the
 * same way as the L1 hello fixture (stock kbuild against Linux 6.12
 * headers); resulting slab.ko is checked into tests/linux-modules/
 * for CI consumption.
 *
 * Expected serial output on insmod:
 *     L3: slab cycle ok
 *     L3: slab.ko module_init
 *
 * Followed by, on rmmod:
 *     L3: slab.ko module_exit
 *
 * The cycle exercises:
 *   - kmem_cache_create   (allocates a handle slot)
 *   - kmem_cache_alloc    (16-byte object out of the slab)
 *   - kmem_cache_free     (returns it to the slab)
 *   - kmem_cache_destroy  (releases the handle slot)
 *
 * Per the L3 shim contract printk is varargs-blind (the shim
 * discards everything past the format string), so this module
 * uses only literal format strings — no %p or %d markers. The
 * cache/object pointers are validated by the shim's own zero-
 * return-on-OOM contract: if any step failed we'd skip the "ok"
 * line and the test harness would notice.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/slab.h>

static struct kmem_cache *l3_cache;

static int __init slab_init(void)
{
    void *obj;

    l3_cache = kmem_cache_create("l3-test", 16, 0, 0, NULL);
    if (!l3_cache)
        return -ENOMEM;

    obj = kmem_cache_alloc(l3_cache, GFP_KERNEL);
    if (!obj) {
        kmem_cache_destroy(l3_cache);
        l3_cache = NULL;
        return -ENOMEM;
    }

    kmem_cache_free(l3_cache, obj);
    kmem_cache_destroy(l3_cache);
    l3_cache = NULL;

    printk(KERN_INFO "L3: slab cycle ok\n");
    printk(KERN_INFO "L3: slab.ko module_init\n");
    return 0;
}

static void __exit slab_exit(void)
{
    printk(KERN_INFO "L3: slab.ko module_exit\n");
}

module_init(slab_init);
module_exit(slab_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L3 test fixture - kmem_cache_* round trip");
MODULE_AUTHOR("Hamnix project");
