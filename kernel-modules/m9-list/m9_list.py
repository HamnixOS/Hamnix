# Pynux M9.2: intrusive doubly-linked list in pure Pynux.
#
# The kernel's `list.h` is entirely static-inline macros: INIT_LIST_HEAD,
# list_add, list_for_each, container_of. None are callable symbols, so
# Pynux implements them itself. This module:
#   * INIT_LIST_HEAD-initializes a list head (self-pointing next/prev)
#   * list_add()s three Node objects in succession
#   * walks the chain and sums their values
# 10 + 20 + 30 = 60 confirms next pointers + container_of-style offset
# arithmetic both work.

extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# struct list_head { struct list_head *next; struct list_head *prev; };
class ListHead:
    next: Ptr[uint8]      # 0
    prev: Ptr[uint8]      # 8

class Node:
    value: int32          # 0..4
    pad:   int32          # 4..8
    link:  ListHead       # 8..24


NODE_LINK_OFF: int32 = 8


pynux_head:  ListHead
pynux_n1:    Node
pynux_n2:    Node
pynux_n3:    Node


def pynux_list_init(head: Ptr[uint8]):
    # head->next = head; head->prev = head
    memcpy(head, &head, 8)
    memcpy(head + 8, &head, 8)


def pynux_list_add(new: Ptr[uint8], head: Ptr[uint8]):
    # __list_add(new, head, head->next):
    #   next->prev = new ; new->next = next ; new->prev = head ; head->next = new
    next_p: Ptr[uint8] = 0
    memcpy(&next_p, head, 8)         # next_p = head->next
    memcpy(next_p + 8, &new, 8)       # next->prev = new
    memcpy(new, &next_p, 8)           # new->next = next
    memcpy(new + 8, &head, 8)         # new->prev = head
    memcpy(head, &new, 8)             # head->next = new


def init_module() -> int32:
    pynux_list_init(&pynux_head)

    pynux_n1.value = 10
    pynux_n2.value = 20
    pynux_n3.value = 30

    # Insert at head: list becomes head → 3 → 2 → 1 → (loop back to head)
    pynux_list_add(&pynux_n1.link, &pynux_head)
    pynux_list_add(&pynux_n2.link, &pynux_head)
    pynux_list_add(&pynux_n3.link, &pynux_head)

    # Walk: for (pos = head->next; pos != head; pos = pos->next).
    head_addr: Ptr[uint8] = &pynux_head
    pos: Ptr[uint8] = 0
    memcpy(&pos, head_addr, 8)
    total: int32 = 0
    while pos != head_addr:
        node_ptr: Ptr[uint8] = pos - NODE_LINK_OFF   # container_of
        node_val: int32 = 0
        memcpy(&node_val, node_ptr, 4)
        total = total + node_val
        memcpy(&pos, pos, 8)
    _printk("[LIST] walked sum = %d\n", total)
    return 0


def cleanup_module():
    _printk("[LIST] unregistered\n", 0)
