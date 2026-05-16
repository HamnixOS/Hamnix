/* tests/linux-modules/src/timer/timer.c
 *
 * The L9/M5.2 test fixture: exercises the timer_list (jiffies-
 * resolution) family. Built the same way as the L1 hello fixture
 * (stock kbuild against Linux 6.12 headers); resulting timer.ko is
 * checked into tests/linux-modules/ for the regression .ko suite.
 *
 * Expected serial output on insmod:
 *     L9: timer armed
 *     L9: timer.ko module_init
 *     L9: timer fired              (after ~50 ms / 5 jiffies)
 *
 * Followed by, on rmmod:
 *     L9: timer.ko module_exit
 *
 * The cycle exercises:
 *   - timer_setup       (records the callback + flags)
 *   - mod_timer         (arm with a jiffies + 5 deadline)
 *   - the dispatcher    (Hamnix's timer_walk_one_tick fires the cb)
 *   - timer_delete_sync (clears the slot on rmmod)
 *
 * Per the L9 shim contract printk is varargs-blind (the shim
 * discards everything past the format string), so this module
 * uses only literal format strings — no %d markers on the jiffies
 * delta.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/timer.h>
#include <linux/jiffies.h>

static struct timer_list l9_timer;

static void l9_timer_cb(struct timer_list *t)
{
    printk(KERN_INFO "L9: timer fired\n");
}

static int __init timer_init_mod(void)
{
    timer_setup(&l9_timer, l9_timer_cb, 0);
    mod_timer(&l9_timer, jiffies + 5);
    printk(KERN_INFO "L9: timer armed\n");
    printk(KERN_INFO "L9: timer.ko module_init\n");
    return 0;
}

static void __exit timer_exit_mod(void)
{
    timer_delete_sync(&l9_timer);
    printk(KERN_INFO "L9: timer.ko module_exit\n");
}

module_init(timer_init_mod);
module_exit(timer_exit_mod);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L9 test fixture - timer_list arm/fire/del");
MODULE_AUTHOR("Hamnix project");
