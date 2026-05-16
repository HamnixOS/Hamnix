/* tests/linux-modules/src/workq/workq.c
 *
 * The L8 / M4.3a test fixture: exercises kthread_create_on_node plus
 * the workqueue (alloc / INIT_WORK / queue_work_on / flush /
 * destroy) round-trip. Built the same way as the L1 hello fixture
 * (stock kbuild against Linux 6.12 headers); resulting workq.ko is
 * checked into tests/linux-modules/ for the regression .ko suite.
 *
 * Expected serial output on insmod:
 *     L8: kthread created
 *     L8: workqueue allocated
 *     L8: work queued
 *     L8: work fn fired
 *     L8: workqueue flushed
 *     L8: workq.ko module_init
 *
 * Followed by, on rmmod:
 *     L8: kthread stopped
 *     L8: workqueue destroyed
 *     L8: workq.ko module_exit
 *
 * The cycle exercises:
 *   - kthread_create_on_node      threadfn + data + node + namefmt
 *   - wake_up_process             flips the kthread runnable
 *   - kthread_should_stop /
 *     kthread_stop                cooperative-exit handshake
 *   - alloc_workqueue             handle allocation
 *   - INIT_WORK                   direct struct write (no kernel sym)
 *   - queue_work_on               record pending work
 *   - flush_workqueue             drain + invoke fn
 *   - destroy_workqueue           release handle
 *
 * Per the L1 shim contract printk is varargs-blind, so this module
 * uses only literal format strings.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/workqueue.h>
#include <linux/sched.h>

static struct task_struct      *l8_kthread;
static struct workqueue_struct *l8_wq;
static struct work_struct       l8_work;

static int l8_kthread_fn(void *arg)
{
    /* The fixture's kthread loop is a no-op spin: real drivers would
     * dequeue items here. We just observe kthread_should_stop so
     * kthread_stop can unwind us on rmmod. Hamnix's cooperative
     * scheduler runs this thread only when other tasks yield, which
     * at L8 means it runs once between module_init's last yield and
     * module_exit's first call into kthread_stop. */
    while (!kthread_should_stop()) {
        schedule_timeout(HZ);
    }
    return 0;
}

static void l8_work_fn(struct work_struct *w)
{
    printk(KERN_INFO "L8: work fn fired\n");
}

static int __init workq_init_mod(void)
{
    l8_kthread = kthread_create(l8_kthread_fn, NULL, "l8_worker");
    if (IS_ERR(l8_kthread))
        return PTR_ERR(l8_kthread);
    wake_up_process(l8_kthread);
    printk(KERN_INFO "L8: kthread created\n");

    l8_wq = alloc_workqueue("l8_wq", 0, 1);
    if (!l8_wq)
        return -ENOMEM;
    printk(KERN_INFO "L8: workqueue allocated\n");

    INIT_WORK(&l8_work, l8_work_fn);
    queue_work(l8_wq, &l8_work);
    printk(KERN_INFO "L8: work queued\n");

    flush_workqueue(l8_wq);
    printk(KERN_INFO "L8: workqueue flushed\n");

    printk(KERN_INFO "L8: workq.ko module_init\n");
    return 0;
}

static void __exit workq_exit_mod(void)
{
    if (l8_kthread) {
        kthread_stop(l8_kthread);
        printk(KERN_INFO "L8: kthread stopped\n");
    }
    if (l8_wq) {
        destroy_workqueue(l8_wq);
        printk(KERN_INFO "L8: workqueue destroyed\n");
    }
    printk(KERN_INFO "L8: workq.ko module_exit\n");
}

module_init(workq_init_mod);
module_exit(workq_exit_mod);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L8 test fixture - kthread + workqueue round trip");
MODULE_AUTHOR("Hamnix project");
