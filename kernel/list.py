# kernel/list.py
#
# Mirrors include/linux/list.h in Linux — the intrusive doubly-linked
# list that every kernel data structure leans on (runqueues, slab
# caches, vmas, file descriptors, you name it). On the .ko side this
# was M9.2; here we bring it across to the bare-metal kernel ABI with
# struct-aware field access instead of the raw-memcpy idiom M9.2 had
# to use against an opaque `Ptr[uint8]`.
#
# A ListHead is a 16-byte struct with two pointers. We store the
# pointers as plain `uint64` rather than `Ptr[ListHead]` to sidestep
# any self-referencing-type complications in the Pynux type resolver:
# pointer size is 8 either way, and the helpers cast to
# `Ptr[ListHead]` at access time when they need typed field access.
#
# The intrusive pattern: callers embed a ListHead inside their own
# struct, link those into chains, and use container_of-style offset
# arithmetic on the way out:
#
#     class Task:
#         data: uint64
#         link: ListHead       # offset 8
#     ...
#     pos: Ptr[ListHead] = cast[Ptr[ListHead]](head.next_ptr)
#     while pos != &head:
#         task: Ptr[Task] = cast[Ptr[Task]](cast[uint64](pos) - 8)
#         ...
#         pos = cast[Ptr[ListHead]](pos[0].next_ptr)
#
# The `- 8` is the byte offset of `link` within `Task`. Linux hides
# that subtraction behind the `container_of` macro; Pynux has no
# macros, so the call sites carry the offset explicitly. When we add
# a Pynux equivalent later it becomes a single helper.


class ListHead:
    next_ptr: uint64       # offset 0
    prev_ptr: uint64       # offset 8


# Poison values written into a deleted node's pointers so a buggy
# use-after-list_del dereference faults visibly instead of silently
# walking off into the kernel. Matches Linux's LIST_POISON1/2 values
# (just numerically distinct addresses guaranteed to be unmapped).
LIST_POISON1: uint64 = 0xDEAD000000000100
LIST_POISON2: uint64 = 0xDEAD000000000200


def INIT_LIST_HEAD(head: Ptr[ListHead]):
    # Empty list: head's next/prev both point at head itself. This is
    # the canonical "circular doubly-linked list" representation —
    # `list_empty(head) == (head->next == head)`.
    addr: uint64 = cast[uint64](head)
    head[0].next_ptr = addr
    head[0].prev_ptr = addr


def list_add(new: Ptr[ListHead], head: Ptr[ListHead]):
    # Insert `new` right after `head` (at the front of the list).
    # __list_add(new, head, head->next):
    #     prev = head;  next = head->next
    #     next->prev = new
    #     new->next  = next
    #     new->prev  = prev
    #     prev->next = new
    head_addr: uint64 = cast[uint64](head)
    new_addr:  uint64 = cast[uint64](new)
    next_addr: uint64 = head[0].next_ptr
    next:      Ptr[ListHead] = cast[Ptr[ListHead]](next_addr)

    next[0].prev_ptr = new_addr
    new[0].next_ptr  = next_addr
    new[0].prev_ptr  = head_addr
    head[0].next_ptr = new_addr


def list_add_tail(new: Ptr[ListHead], head: Ptr[ListHead]):
    # Insert `new` right before `head` (at the back of the list).
    # __list_add(new, head->prev, head): the symmetric variant.
    head_addr: uint64 = cast[uint64](head)
    new_addr:  uint64 = cast[uint64](new)
    prev_addr: uint64 = head[0].prev_ptr
    prev:      Ptr[ListHead] = cast[Ptr[ListHead]](prev_addr)

    head[0].prev_ptr = new_addr
    new[0].next_ptr  = head_addr
    new[0].prev_ptr  = prev_addr
    prev[0].next_ptr = new_addr


def list_del(node: Ptr[ListHead]):
    # Unlink `node` from its containing list, then poison its
    # pointers. Reusing the node after this is a bug — the poison
    # guarantees the bug manifests as a page fault rather than silent
    # corruption.
    prev: Ptr[ListHead] = cast[Ptr[ListHead]](node[0].prev_ptr)
    next: Ptr[ListHead] = cast[Ptr[ListHead]](node[0].next_ptr)
    prev[0].next_ptr = node[0].next_ptr
    next[0].prev_ptr = node[0].prev_ptr
    node[0].next_ptr = LIST_POISON1
    node[0].prev_ptr = LIST_POISON2


def list_empty(head: Ptr[ListHead]) -> int32:
    # 1 if head is the only element in its own circular chain, else 0.
    if head[0].next_ptr == cast[uint64](head):
        return 1
    return 0
