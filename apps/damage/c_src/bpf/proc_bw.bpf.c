// SPDX-License-Identifier: GPL-2.0
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, u32);      // pid
    __type(value, u64);     // bytes
    __uint(max_entries, 65536);
} bytes_tx SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, u32);      // pid
    __type(value, u64);     // bytes
    __uint(max_entries, 65536);
} bytes_rx SEC(".maps");

static __always_inline void add_bytes(struct bpf_map_def *map, u32 pid, u64 n) {
    // libbpf CO-RE needs bpf_map_update_elem; but inline helper above is fine
    u64 zero = 0;
    u64 *cur = bpf_map_lookup_elem(map, &pid);
    if (!cur) {
        bpf_map_update_elem(map, &pid, &zero, BPF_ANY);
        cur = bpf_map_lookup_elem(map, &pid);
        if (!cur) return;
    }
    __sync_fetch_and_add(cur, n);
}

SEC("kprobe/tcp_sendmsg")
int BPF_KPROBE(kp_tcp_sendmsg, struct sock *sk, struct msghdr *msg, size_t size) {
    u32 pid = (u32)(bpf_get_current_pid_tgid() >> 32);
    add_bytes((void *)&bytes_tx, pid, size);
    return 0;
}

// int tcp_cleanup_rbuf(struct sock *sk, int copied, int copied_early)
SEC("kprobe/tcp_cleanup_rbuf")
int BPF_KPROBE(kp_tcp_cleanup_rbuf, struct sock *sk, int copied, int copied_early) {
    if (copied <= 0) return 0;
    u32 pid = (u32)(bpf_get_current_pid_tgid() >> 32);
    add_bytes((void *)&bytes_rx, pid, (u64)copied);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
