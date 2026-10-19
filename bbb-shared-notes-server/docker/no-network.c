/*
 * no-network — run a command without network access.
 *
 * Usage: no-network <command> [args …]
 *
 * The container replacement of run-in-systemd.sh runs the PDF converter through this program,
 * in place of the PrivateNetwork=true and IPAddressDeny=any properties of the bare-metal unit.
 * It installs a seccomp filter and then executes the command; the filter is inherited by every
 * process the command starts and cannot be removed. Installing it needs no privileges
 * (PR_SET_NO_NEW_PRIVS first), so it works under any UID, with a read-only root file system,
 * with Docker's and Kubernetes' default seccomp profiles (RuntimeDefault) and without
 * capabilities.
 *
 * Denied (EACCES, or EPERM):
 *   socket()            every address family: no socket can be created, so no connection to any
 *                       address, loopback included, and no name resolution
 *   io_uring_setup()    io_uring can create and connect sockets without socket()
 *   pidfd_getfd(), ptrace(), process_vm_readv(), process_vm_writev()
 *                       taking a socket from, or running code in, another process of the user
 *   any system call of another ABI (i386, x32), which the filter's numbers do not cover
 *
 * socketpair() stays allowed: it creates a connected pair within the process, nothing else can
 * reach it. If the filter cannot be installed, the command is not run (exit status 126).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__x86_64__)
#define NATIVE_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define NATIVE_ARCH AUDIT_ARCH_AARCH64
#else
#error "no-network: unsupported architecture"
#endif

#define DENY(nr, err) \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 1), \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ((err) & SECCOMP_RET_DATA))

int main(int argc, char *argv[])
{
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NATIVE_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
#if defined(__x86_64__)
        /* x32 system calls share the arch value and set this bit in the number */
        BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
#endif
        DENY(__NR_socket, EACCES),
        DENY(__NR_io_uring_setup, EPERM),
        DENY(__NR_pidfd_getfd, EPERM),
        DENY(__NR_ptrace, EPERM),
        DENY(__NR_process_vm_readv, EPERM),
        DENY(__NR_process_vm_writev, EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = {
        .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])),
        .filter = filter,
    };

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args …]\n", argv[0]);
        return 2;
    }
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
        || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0) != 0) {
        fprintf(stderr, "no-network: cannot install the seccomp filter: %s\n", strerror(errno));
        return 126;
    }
    execvp(argv[1], &argv[1]);
    fprintf(stderr, "no-network: %s: %s\n", argv[1], strerror(errno));
    return errno == ENOENT ? 127 : 126;
}
