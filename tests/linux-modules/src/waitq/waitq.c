/* tests/linux-modules/src/waitq/waitq.c
 *
 * The L7 / M4.1 test fixture: exercises the wait_queue primitives
 * that real drivers (UART RX, block device completion, anything
 * with a "data not ready, sleep" pattern) rely on. Built the same
 * way as the L1 hello fixture (stock kbuild against Linux 6.12
 * headers); resulting waitq.ko is checked into tests/linux-modules/
 * for the regression .ko suite.
 *
 * Expected serial output on insmod:
 *     L7: waitq initialised
 *     L7: waitq wake_up delivered
 *     L7: waitq wait_event observed wake
 *     L7: waitq.ko module_init
 *
 * Followed by, on rmmod:
 *     L7: waitq.ko module_exit
 *
 * The cycle exercises:
 *   - __init_waitqueue_head    via DECLARE_WAIT_QUEUE_HEAD's runtime
 *                              init_waitqueue_head macro
 *   - prepare_to_wait /
 *     finish_wait              the wait_event idiom's inner loop
 *   - __wake_up                via wake_up()
 *   - schedule_timeout         courtesy yield in the sleep path
 *
 * Because Hamnix is uniprocessor + cooperative at L7, wake_up() is
 * called BEFORE the wait_event-like loop runs — the loop exits on
 * its first observation. A future fixture that splits wake from
 * wait into sibling tasks would exercise the cooperative-yield path
 * inside the L7 shim. Per the L1 shim contract printk is varargs-
 * blind, so this module uses only literal format strings.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/wait.h>
#include <linux/sched.h>

static DECLARE_WAIT_QUEUE_HEAD(l7_wq);
static int l7_condition;

static int __init waitq_init_mod(void)
{
    DEFINE_WAIT(wait);

    /* Re-init explicitly so the shim's __init_waitqueue_head path
     * (not just the static DECLARE_WAIT_QUEUE_HEAD initialiser) is
     * exercised. Real drivers do this when the wait_queue_head is
     * embedded in a kmalloc'd struct rather than a static. */
    init_waitqueue_head(&l7_wq);
    printk(KERN_INFO "L7: waitq initialised\n");

    /* Producer side: set the condition and wake the queue BEFORE
     * the wait loop runs (uniprocessor cooperative — see file
     * comment). */
    l7_condition = 1;
    wake_up(&l7_wq);
    printk(KERN_INFO "L7: waitq wake_up delivered\n");

    /* Consumer side: the wait_event idiom inlined so we can see
     * each shim being called. In real drivers this is
     *     wait_event_timeout(l7_wq, l7_condition, HZ);
     * which expands to roughly this loop. */
    prepare_to_wait(&l7_wq, &wait, TASK_INTERRUPTIBLE);
    if (!l7_condition)
        schedule_timeout(HZ / 10);
    finish_wait(&l7_wq, &wait);
    printk(KERN_INFO "L7: waitq wait_event observed wake\n");

    printk(KERN_INFO "L7: waitq.ko module_init\n");
    return 0;
}

static void __exit waitq_exit_mod(void)
{
    printk(KERN_INFO "L7: waitq.ko module_exit\n");
}

module_init(waitq_init_mod);
module_exit(waitq_exit_mod);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L7 test fixture - wait_queue prepare/wake/finish");
MODULE_AUTHOR("Hamnix project");
