/* tests/linux-modules/src/proc/proc.c
 *
 * The L5 test fixture: a minimum-meaningful stock Linux 6.12 module
 * that registers a /proc entry and tears it down. Exercises the
 * proc_create / proc_remove half of the procfs ABI (the read-side
 * dispatch through proc_ops.proc_read lands in a later milestone;
 * for L5 we only verify the registration shims accept the call and
 * hand back a non-NULL handle).
 *
 * Expected serial output when Hamnix's L5 insmod loads this:
 *     L5: proc_create returned <non-NULL pointer>
 *
 * Followed by, on rmmod:
 *     L5: proc.ko module_exit
 *
 * Mirrors the L1 hello/ fixture's Makefile pattern; built with stock
 * kbuild against Linux 6.12 headers and stashed at
 * tests/linux-modules/proc.ko for the regression .ko suite.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>

static struct proc_dir_entry *l5_entry;

static int l5_show(struct seq_file *m, void *v)
{
    seq_puts(m, "hamnix L5 procfs fixture\n");
    return 0;
}

static int l5_open(struct inode *inode, struct file *file)
{
    return single_open(file, l5_show, NULL);
}

static const struct proc_ops l5_pops = {
    .proc_open    = l5_open,
    .proc_read    = seq_read,
    .proc_lseek   = seq_lseek,
    .proc_release = single_release,
};

static int __init proc_init(void)
{
    l5_entry = proc_create("hamnix_l5", 0644, NULL, &l5_pops);
    printk(KERN_INFO "L5: proc_create returned %p\n", l5_entry);
    return 0;
}

static void __exit proc_exit(void)
{
    proc_remove(l5_entry);
    printk(KERN_INFO "L5: proc.ko module_exit\n");
}

module_init(proc_init);
module_exit(proc_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hamnix L5 test fixture — procfs registration");
MODULE_AUTHOR("Hamnix project");
