/* Copyright (c) 2017 Julia Computing Inc and contributors */
#define _GNU_SOURCE

/*
  sandbox.c - Sandbox execution platform

This file serves as the entrypoint into our sandboxed/virtualized execution environment for
BinaryBuilder.jl; it has two execution modes:

  1) Unprivileged container mode.
  2) Privileged container mode.

The two modes do similar things, but in different orders and with different privileges. Eventually,
all modes seek the same result; to run a user program with the base root fs and any other shards
requested by the user within the BinaryBuilder.jl execution environment:

* Unprivileged container mode is the "normal" mode of execution; it attempts to use the native
kernel namespace abilities to setup its environment without ever needing to be `root`. It does this
by creating a user namespace, then using its root privileges within the namespace to mount the
necesary shards, `chroot`, etc... within the right places in the new mount namespace created within
the container.

* Privileged container mode is what happens when `sandbox` is invoked with EUID == 0.  In this
mode, the mounts and chroots and whatnot are performed _before_ creating a new user namespace.
This is used as a workaround for kernels that do not have the capabilities for creating mounts
within user namespaces.  Arch Linux is a great example of this.

To test this executable, compile it with:

    gcc -O2 -static -static-libgcc -std=c99 -o /tmp/sandbox ./userns_sandbox.c

Then run it, mounting in a rootfs with a workspace and no other read-only maps:

    mkdir -p /tmp/workspace
    /tmp/sandbox --verbose --rootfs $rootfs_dir --workspace /tmp/workspace:/workspace --cd /workspace /bin/bash
*/


/* Seperate because the headers below don't have all dependencies properly
   declared */
#include <sys/socket.h>

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <linux/socket.h>
#include <linux/if.h>
#include <linux/in.h>
#include <linux/netlink.h>
#include <linux/route.h>
#include <linux/rtnetlink.h>
#include <linux/sockios.h>
#include <linux/veth.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dirent.h>
#include <libgen.h>
#include <sys/reboot.h>
#include <linux/reboot.h>
#include <linux/limits.h>
#include <getopt.h>
#include <byteswap.h>
#include <mntent.h>

/**** Global Variables ***/
#define TRUE 1
#define FALSE 0

// sandbox_root is the location of the rootfs on disk.  This is required.
char *sandbox_root = NULL;

// new_cd is where we will cd to once we start running.
char *new_cd = NULL;

// persist_dir is where we will store overlayfs data.
// Specifying this will allow subsequent invocations to persist temporary state.
char * persist_dir = NULL;

// verbose sets whether we're in verbose mode.
unsigned char verbose = 0;

// Linked list of volume mappings
struct map_list {
    char *map_path;
    char *outside_path;
    struct map_list *prev;
};
struct map_list *maps;
struct map_list *workspaces;

// This keeps track of our execution mode
enum {
  UNPRIVILEGED_CONTAINER_MODE,
  PRIVILEGED_CONTAINER_MODE,
};
static int execution_mode;

/**** General Utilities ***/

/* Like assert, but don't go away with optimizations */
static void _check(int ok, int line) {
  if (!ok) {
    fprintf(stderr, "At line %d, ABORTED (%d: %s)!\n", line, errno, strerror(errno));
    fflush(stdout);
    fflush(stderr);
    _exit(1);
  }
}
#define check(ok) _check(ok, __LINE__)

/* Opens /proc/%pid/%file */
static int open_proc_file(pid_t pid, const char *file, int mode) {
  char path[PATH_MAX];
  int n = snprintf(path, sizeof(path), "/proc/%d/%s", pid, file);
  check(n >= 0 && n < sizeof(path));
  int fd = open(path, mode);
  check(fd != -1);
  return fd;
}

/* `touch` a file; create it if it doesn't already exist. */
static void touch(const char * path) {
  int fd = open(path, O_RDONLY | O_CREAT, S_IRUSR | S_IRGRP | S_IROTH);
  // Ignore EISDIR as sometimes we try to `touch()` a directory
  if (fd == -1 && errno != EISDIR) {
    check(fd != -1);
  }
  close(fd);
}

/* Make all directories up to the given directory name. */
static void mkpath(const char * dir) {
  // If this directory already exists, back out.
  DIR * dir_obj = opendir(dir);
  if (dir_obj) {
    closedir(dir_obj);
    return;
  }
  errno = 0;

  // Otherwise, first make sure our parent exists.  Note that dirname()
  // clobbers its input, so we copy to a temporary variable first. >:|
  char dir_dirname[PATH_MAX];
  strncpy(dir_dirname, dir, PATH_MAX);
  mkpath(dirname(&dir_dirname[0]));

  // then create our directory
  int result = mkdir(dir, 0777);
  check((0 == result) || (errno == EEXIST));
}

static int isdir(const char * path) {
  struct stat path_stat;
  int result = stat(path, &path_stat);

  // Silently ignore calling `isdir()` on a non-existant path
  check((0 == result) || (errno == ENOENT) || (errno == ENOTDIR));
  return S_ISDIR(path_stat.st_mode);
}

static int islink(const char * path) {
  struct stat path_stat;
  int result = stat(path, &path_stat);

  // Silently ignore calling `islink()` on a non-existant path
  check((0 == result) || (errno == ENOENT) || (errno == ENOTDIR));
  return S_ISLNK(path_stat.st_mode);
}

/**** Signal handling *****
 *
 * We will support "passing through" signals to the child process transparently,
 * for a predefined set of signals, which we set up here.  The signal chain will
 * pass from the 'outer' sandbox process (e.g. the parent of `clone()`) to the
 * 'inner' sandbox process (e.g. the parent of `fork()`), and finally to the
 * actual target process (e.g. the child of `fork()`).
 */

pid_t child_pid;
static void signal_passthrough(int sig) {
  kill(child_pid, sig);
}

// The list of signals that we will forward to our child process
int forwarded_signals[] = {
  SIGHUP,
  SIGPIPE,
  SIGSTOP,
  SIGINT,
  SIGTERM,
  SIGUSR1,
  SIGUSR2,
};

static void setup_signal_forwarding() {
  for (int idx=0; idx<sizeof(forwarded_signals)/sizeof(int); idx++) {
    signal(forwarded_signals[idx], signal_passthrough);
  }
}

/**** User namespaces *****
 *
 * For a general overview on user namespaces, see the corresponding manual page
 * user_namespaces(7). In general, user namespaces allow unprivileged users to
 * run privileged executables, by rewriting uids inside the namespaces (and
 * in particular, a user can be root inside the namespace, but not outside),
 * with the kernel still enforcing access protection as if the user was
 * unprivilged (to all files and resources not created exclusively within the
 * namespace). Absent kernel bugs, this provides relatively strong protections
 * against misconfiguration (because no true privilege is ever bestowed upon
 * the sandbox). It should be noted however, that there were such kernel bugs
 * as recently as Feb 2016.  These were sneaky privilege escalation bugs,
 * rather unimportant to the use case of BinaryBuilder, but a recent and fully
 * patched kernel should be considered essential for any security-sensitive
 * work done on top of this infrastructure).
 */
static void configure_user_namespace(pid_t pid, uid_t src_uid, gid_t src_gid,
                                     uid_t dst_uid, gid_t dst_gid) {
  int nbytes = 0;

  if (verbose) {
    fprintf(stderr, "--> Mapping %d:%d to %d:%d within container namespace\n",
            src_uid, src_gid, dst_uid, dst_gid);
  }

  // Setup uid map
  int uidmap_fd = open_proc_file(pid, "uid_map", O_WRONLY);
  check(uidmap_fd != -1);
  char uidmap[100];
  nbytes = snprintf(uidmap, sizeof(uidmap), "%d\t%d\t1\n", dst_uid, src_uid);
  check(nbytes > 0 && nbytes <= sizeof(uidmap));
  check(write(uidmap_fd, uidmap, nbytes) == nbytes);
  close(uidmap_fd);

  // Deny setgroups
  int setgroups_fd = open_proc_file(pid, "setgroups", O_WRONLY);
  char deny[] = "deny";
  check(write(setgroups_fd, deny, sizeof(deny)) == sizeof(deny));
  close(setgroups_fd);

  // Setup gid map
  int gidmap_fd = open_proc_file(pid, "gid_map", O_WRONLY);
  check(gidmap_fd != -1);
  char gidmap[100];
  nbytes = snprintf(gidmap, sizeof(gidmap), "%d\t%d\t1", dst_gid, src_gid);
  check(nbytes > 0 && nbytes <= sizeof(gidmap));
  check(write(gidmap_fd, gidmap, nbytes) == nbytes);
}


/*
 * Mount an overlayfs from `src` onto `dest`, anchoring the changes made to the overlayfs
 * within the folders `work_dir`/upper and `work_dir`/work.  Note that the common case of
 * `src` == `dest` signifies that we "shadow" the original source location and will simply
 * discard any changes made to it when the overlayfs disappears.  This is how we protect our
 * rootfs and shards when mounting from a local filesystem, as well as how we convert a
 * read-only rootfs and shards to a read-write system when mounting from squashfs images.
 */
static void mount_overlay(const char * src, const char * dest, const char * bname,
                          const char * work_dir, uid_t uid, gid_t gid) {
  char upper[PATH_MAX], work[PATH_MAX], opts[3*PATH_MAX+28];

  // Construct the location of our upper and work directories
  snprintf(upper, sizeof(upper), "%s/upper/%s", work_dir, bname);
  snprintf(work, sizeof(work), "%s/work/%s", work_dir, bname);

  // If `src` or `dest` is "", we actually want it to be "/", so adapt here because
  // this is the only place in the code base where we actually need the slash at the
  // end of the directory name.
  if (src[0] == '\0') {
    src = "/";
  }
  if (dest[0] == '\0') {
    dest = "/";
  }

  if (verbose) {
    fprintf(stderr, "--> Mounting overlay of %s at %s (modifications in %s, workspace in %s)\n", src, dest, upper, work);
  }

  // Make the upper and work directories
  mkpath(upper);
  mkpath(work);

  // Construct the opts, mount the overlay
  snprintf(opts, sizeof(opts), "lowerdir=%s,upperdir=%s,workdir=%s", src, upper, work);
  check(0 == mount("overlay", dest, "overlay", 0, opts));

  // Chown this directory to the desired UID/GID, so that it doesn't look like it's
  // owned by "nobody" when we're inside the sandbox.
  check(0 == chown(dest, uid, gid));
}

static void mount_procfs(const char * root_dir, uid_t uid, gid_t gid) {
  char path[PATH_MAX];

  // Mount procfs at <root_dir>/proc
  snprintf(path, sizeof(path), "%s/proc", root_dir);
  if (verbose) {
    fprintf(stderr, "--> Mounting procfs at %s\n", path);
  }
  // Attempt to unmount a previous /proc if it exists
  check(0 == mount("proc", path, "proc", 0, ""));

  // Chown this directory to the desired UID/GID, so that it doesn't look like it's
  // owned by "nobody" when we're inside the sandbox.  We allow this to fail, as
  // sometimes we're trying to chown() something we don't own.
  int ignored = chown(path, uid, gid);
}

static void bind_mount(const char *src, const char *dest, char read_only) {
  // If `src` is a symlink, this bindmount may run into issues, so we collapse
  // `src` via `realpath()` to ensure that we get a non-symlink.
  char resolved_src[PATH_MAX] = {0};
  if (islink(src)) {
    if (NULL == realpath(src, resolved_src)) {
      if (verbose) {
        fprintf(stderr, "WARNING: Unable to resolve %s ([%d] %s)\n", src, errno, strerror(errno));
      }
    }
  }

  if (resolved_src[0] == '\0') {
    strncpy(resolved_src, src, PATH_MAX);
  }

  if (verbose) {
    if (read_only) {
      fprintf(stderr, "--> Bind-mounting %s over %s (read-only)\n", resolved_src, dest);
    } else {
      fprintf(stderr, "--> Bind-mounting %s over %s (read-write)\n", resolved_src, dest);
    }
  }

  // If we're mounting in a directory, create the mountpoint as a directory,
  // otherwise as a file.  Note that if `src` does not exist, we'll create a
  // file here, then error out on the `mount()` call.
  if (isdir(resolved_src)) {
    mkpath(dest);
  } else {
    touch(dest);
  }

  // We don't expect workspaces to have any submounts in normal operation.
  // However, for runshell(), workspace could be an arbitrary directory,
  // including one with sub-mounts, so allow that situation with MS_REC.
  check(0 == mount(resolved_src, dest, "", MS_BIND|MS_REC, NULL));

  // remount to read-only. this requires a separate remount:
  // https://git.kernel.org/pub/scm/utils/util-linux/util-linux.git/commit/?id=9ac77b8a78452eab0612523d27fee52159f5016a
  // during such a remount, we're not allowed to clear locked mount flags:
  // https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=9566d6742852c527bf5af38af5cbb878dad75705
  if (read_only) {
    // we cannot apply locked mount flags blindly, because they change behaviour of the
    // mount (e.g. noexec), so figure out which ones we need by looking at mtab.
    struct stat src_stat;
    stat(resolved_src, &src_stat);

    struct mntent *mnt = NULL;
    FILE * mtab = setmntent("/etc/mtab", "r");
    check(mtab != NULL);
    while (mnt = getmntent(mtab)) {
        struct stat dev_stat;
        // It's possible that we try to stat() something that we're
        // not allowed to look at; if that occurs, skip it, hoping
        // that it's not the mount we're actually interested in.
        if (stat(mnt->mnt_dir, &dev_stat) == 0 &&
            dev_stat.st_dev == src_stat.st_dev)
            break;

        // Don't let a non-matching `mnt` leak through, in the event
        // that we never find the device the mount belongs to.
        mnt = NULL;
    }
    endmntent(mtab);

    // This will fail if we never found the matching `mnt`.
    check(mnt != NULL);

    int locked_flags = 0;
    char *mnt_opt;
    mnt_opt = strtok(mnt->mnt_opts, ",");
    while (mnt_opt != NULL) {
        if (strcmp(mnt_opt, "nodev") == 0)
            locked_flags |= MS_NODEV;
        else if (strcmp(mnt_opt, "nosuid") == 0)
            locked_flags |= MS_NOSUID;
        else if (strcmp(mnt_opt, "noexec") == 0)
            locked_flags |= MS_NOEXEC;
        else if (strcmp(mnt_opt, "noatime") == 0)
            locked_flags |= MS_NOATIME;
        else if (strcmp(mnt_opt, "nodiratime") == 0)
            locked_flags |= MS_NODIRATIME;
        else if (strcmp(mnt_opt, "relatime") == 0)
            locked_flags |= MS_RELATIME;
        mnt_opt = strtok(NULL, ",");
    }
    check(0 == mount(resolved_src, dest, "", MS_BIND|MS_REMOUNT|MS_RDONLY|locked_flags, NULL));
  }
}

static void bind_host_node(const char *root_dir, const char *name, char read_only) {
  char path[PATH_MAX];
  if (access(name, F_OK) == 0) {
    snprintf(path, sizeof(path), "%s/%s", root_dir, name);
    bind_mount(name, path, read_only);
  }
}

/*
 * We use this method to get /dev in shape.  If we're running as init, we need to
 * mount full-blown devtmpfs at /dev.  If we're just a sandbox, we only bindmount
 * /dev/{tty,null,urandom,pts,ptmx} into our root_dir.
 */
static void mount_dev(const char * root_dir) {
  char path[PATH_MAX];

  // These are all things that should exist in the host environment, but may not
  // We use `bind_host_node()` to bindmount them into our sandbox if they exist.
  bind_host_node(root_dir, "/dev/null", FALSE);
  bind_host_node(root_dir, "/dev/tty", FALSE);
  bind_host_node(root_dir, "/dev/zero", FALSE);
  bind_host_node(root_dir, "/dev/random", FALSE);
  bind_host_node(root_dir, "/dev/urandom", FALSE);
  bind_host_node(root_dir, "/dev/shm", FALSE);

  // Bindmount the sysfs, but make it read-only
  bind_host_node(root_dir, "/sys", TRUE);

  // /dev/pts and /dev/ptmx are more special; we actually mount a new filesystem
  // on /dev/pts, and then bind-mount /dev/pts/ptmx to /dev/ptmx within the
  // sandbox itself.
  snprintf(path, sizeof(path), "%s/dev/pts", root_dir);
  mkpath(path);
  check(0 == mount("devpts", path, "devpts", 0, "ptmxmode=0666"));

  snprintf(path, sizeof(path), "%s/dev/pts/ptmx", root_dir);
  char ptmx_dst[PATH_MAX];
  snprintf(ptmx_dst, sizeof(ptmx_dst), "%s/dev/ptmx", root_dir);
  bind_mount(path, ptmx_dst, FALSE);
}

static void mount_maps(const char * dest, struct map_list * workspaces, uint8_t read_only) {
  char path[PATH_MAX];

  struct map_list *current_entry = workspaces;
  while( current_entry != NULL ) {
    char *inside = current_entry->map_path;

    // take the path relative to root_dir
    while (inside[0] == '/') {
      inside = inside + 1;
    }
    snprintf(path, sizeof(path), "%s/%s", dest, inside);

    // bind-mount the outside path to the inside path
    bind_mount(current_entry->outside_path, path, read_only);
    current_entry = current_entry->prev;
  }
}

/*
 * Helper function that mounts pretty much everything:
 *   - procfs
 *   - our overlay work directory
 *   - the rootfs
 *   - the shards
 *   - the workspace (if given by the user)
 */
static void mount_the_world(const char * root_dir,
                            struct map_list * shard_maps,
                            struct map_list * workspaces,
                            uid_t uid, gid_t gid,
                            const char * persist_dir,
                            const char * tmpfs_size) {
  // If `persist_dir` is specified, it represents a host directory that should
  // be used to store our overlayfs work data.  This is where modifications to
  // the rootfs and such will go.  Typically, these should be ephemeral (and if
  // `persist_dir` is `NULL`, it will be mounted in a `tmpfs` so that the
  // modifcations are lost immediately) but if `persist_dir` is given, the
  // mounting will be done with modifications stored in that directory.
  // The caller will be responsible for cleaning up the `work` and `upper`
  // directories wtihin `persist_dir`, but subsequent invocations of `sandbox`
  // with the same `--persist` argument will allow resuming execution inside of
  // a rootfs with the previous modifications intact.
  if (persist_dir == NULL) {
    // We know that `/proc` will always be available on basically any Linux
    // system, so we mount our tmpfs here.  It's also convenient because we
    // will mount an actual `procfs` over this at the end of this function, so
    // the overlayfs work directories are completely hidden from view.
    persist_dir = "/proc";

    // Create tmpfs to store ephemeral changes.  These changes are lost once
    // the `tmpfs` is unmounted, which occurs when all processes within the
    // namespace exit and the mount namespace is destroyed.
    char options[32];
    int n = snprintf(options, 32, "size=%s", tmpfs_size);
    check(0 < n);
    check(n < 31);
    check(0 == mount("tmpfs", "/proc", "tmpfs", 0, options));
  }

  if (verbose) {
    fprintf(stderr, "--> Creating overlay workdir at %s\n", persist_dir);
  }

  // The first thing we do is create an overlay mounting `root_dir` over itself.
  // `root_dir` is the path to the already loopback-mounted rootfs image, and we
  // are mounting it as an overlay over itself, so that we can make modifications
  // without altering the actual rootfs image.  When running in privileged mode,
  // we're mounting before cloning, in unprivileged mode, we clone before calling
  // this mehod at all.sta
  mount_overlay(root_dir, root_dir, "rootfs", persist_dir, uid, gid);

  // Now that we've registered persist_dit put /proc back in its place in the big world.
  // This is necessary for certain libc APIs to function correctly again.
  if (strcmp(persist_dir, "/proc") == 0) {
    mount_procfs("", uid, gid);
  }

  // Mount all of our read-only mounts
  mount_maps(root_dir, shard_maps, TRUE);

  // Mount /proc within the sandbox.
  mount_procfs(root_dir, uid, gid);

  // Mount /dev stuff
  mount_dev(root_dir);

  // Mount all our read-write mounts (workspaces)
  mount_maps(root_dir, workspaces, FALSE);
}

/*
 * Sets up the chroot jail, then executes the target executable.
 */
static int sandbox_main(const char * root_dir, const char * new_cd, int sandbox_argc, char **sandbox_argv, int *parent_pipe) {
  int status;

  // One of the few places where we need to not use `""`, but instead expand it to `"/"`
  if (root_dir[0] == '\0') {
    root_dir = "/";
  }

  // Use `pivot_root()` to avoid bad interaction between `chroot()` and `clone()`,
  // where we get an EPERM on nested sandboxing.
  if (verbose) {
    fprintf(stderr, "Entering rootfs at %s\n", root_dir);
  }
  check(0 == chdir(root_dir));
  if (syscall(SYS_pivot_root, ".", ".") == 0) {
    // Unmount `.`, which will unmount the old root, since that's the first mountpoint in this directory
    check(0 == umount2(".", MNT_DETACH));
    check(0 == chdir("/"));

    if (verbose) {
      fprintf(stderr, "--> pivot_root() succeeded and unmounted old root\n");
    }
  } else {
    check(0 == chroot(root_dir));
    if (verbose) {
      fprintf(stderr, "--> chroot() used since pivot_root() errored with: [%d] %s, nested sandboxing unavailable\n", errno, strerror(errno));
    }
  }

  // If we've got a directory to change to, do so, creating it if we need to
  if (new_cd) {
    mkpath(new_cd);
    check(0 == chdir(new_cd));
  }

  // When the main pid dies, we exit.
  if ((child_pid = fork()) == 0) {
    if (verbose) {
      fprintf(stderr, "About to run `%s` ", sandbox_argv[0]);
      int argc_i;
      for( argc_i=1; argc_i<sandbox_argc; ++argc_i) {
        fprintf(stderr, "`%s` ", sandbox_argv[argc_i]);
      }
      fprintf(stderr, "\n");
    }
    execve(sandbox_argv[0], sandbox_argv, environ);
    fprintf(stderr, "ERROR: Failed to run %s: %d (%s)\n", sandbox_argv[0], errno, strerror(errno));

    // Flush to make sure we've said all we're going to before we _exit()
    fflush(stdout);
    fflush(stderr);
    _exit(1);
  }

  // We want to pass signals through to our child
  setup_signal_forwarding();

  // Let's perform normal init functions, handling signals from orphaned
  // children, etc
  sigset_t waitset;
  sigemptyset(&waitset);
  sigaddset(&waitset, SIGCHLD);
  sigprocmask(SIG_BLOCK, &waitset, NULL);
  for (;;) {
    int sig;
    sigwait(&waitset, &sig);

    pid_t reaped_pid;
    while ((reaped_pid = waitpid(-1, &status, 0)) != -1) {
      if (reaped_pid == child_pid) {
        // If it was the main pid that exited, we're going to exit too.
        // If we died of a signal, return that signal + 256, which we will
        // notice on the other end as a signal.
        if (WIFSIGNALED(status)) {
          unsigned int reported_exit_code = 256 + WTERMSIG(status);
          check(sizeof(unsigned int) == write(parent_pipe[1], &reported_exit_code, sizeof(unsigned int)));
          return 0;
        }
        if (WIFEXITED(status)) {
          // Normal exits get reported in a more straightforward fashion
          unsigned int reported_exit_code = WEXITSTATUS(status);
          check(sizeof(unsigned int) == write(parent_pipe[1], &reported_exit_code, sizeof(unsigned int)));
          return 0;
        }

        // Unsure what's going on here, but it isn't good.
        check(-1);
      }
    }
  }
}

static void print_help() {
  fputs("Usage: sandbox --rootfs <dir> [--cd <dir>] ", stderr);
  fputs("[--map <from>:<to>, --map <from>:<to>, ...] ", stderr);
  fputs("[--workspace <from>:<to>, --workspace <from>:<to>, ...] ", stderr);
  fputs("[--persist <work_dir>] ", stderr);
  fputs("[--entrypoint <exe_path>] ", stderr);
  fputs("[--verbose] [--help] <cmd>\n", stderr);
  fputs("\nExample:\n", stderr);
  fputs("  mkdir -p /tmp/workspace\n", stderr);
  fputs("  /tmp/sandbox --verbose --rootfs $rootfs_path --workspace /tmp/workspace:/workspace --cd /workspace /bin/bash\n", stderr);
}

/*
 * Let's get this party started.
 */
int main(int sandbox_argc, char **sandbox_argv) {
  int status = 0;
  pid_t pgrp = getpgid(0);
  char * entrypoint = NULL;
  const char * hostname = NULL;

  // First, determine our execution mode based on pid and euid (allowing for override)
  const char * forced_mode = getenv("FORCE_SANDBOX_MODE");
  if (forced_mode != NULL) {
    if (strcmp(forced_mode, "privileged") == 0) {
      execution_mode = PRIVILEGED_CONTAINER_MODE;
    } else if (strcmp(forced_mode, "unprivileged") == 0) {
      execution_mode = UNPRIVILEGED_CONTAINER_MODE;
    } else {
      fprintf(stderr, "ERROR: Unknown FORCE_SANDBOX_MODE argument \"%s\"\n", forced_mode);
      _exit(1);
    }
  } else {
    if(geteuid() == 0) {
      execution_mode = PRIVILEGED_CONTAINER_MODE;
    } else {
      execution_mode = UNPRIVILEGED_CONTAINER_MODE;
    }

    // Once we're inside the sandbox, we can always use "unprivileged" mode
    // since we've got mad permissions inside; so just always do that.
    setenv("FORCE_SANDBOX_MODE", "unprivileged", 0);
  }

  uid_t uid = getuid();
  gid_t gid = getgid();

  // If we're running inside of `sudo`, we need to grab the UID/GID of the calling user through
  // environment variables, not using `getuid()` or `getgid()`.  :(
  const char * SUDO_UID = getenv("SUDO_UID");
  if (SUDO_UID != NULL && SUDO_UID[0] != '\0') {
    uid = strtol(SUDO_UID, NULL, 10);
  }
  const char * SUDO_GID = getenv("SUDO_GID");
  if (SUDO_GID != NULL && SUDO_GID[0] != '\0') {
    gid = strtol(SUDO_GID, NULL, 10);
  }

  // Hide these from children so that we don't carry the outside UID numbers into
  // nested sandboxen; that would cause problems when we refer to UIDs that don't exist.
  unsetenv("SUDO_UID");
  unsetenv("SUDO_GID");

  uid_t dst_uid = 0;
  gid_t dst_gid = 0;

  char * tmpfs_size = "1G"; // default value if the `--tmpfs-size` option is not provided

  // Parse out options
  while(1) {
    static struct option long_options[] = {
      {"help",       no_argument,       NULL, 'h'},
      {"verbose",    no_argument,       NULL, 'v'},
      {"rootfs",     required_argument, NULL, 'r'},
      {"workspace",  required_argument, NULL, 'w'},
      {"entrypoint", required_argument, NULL, 'e'},
      {"persist",    required_argument, NULL, 'p'},
      {"cd",         required_argument, NULL, 'c'},
      {"map",        required_argument, NULL, 'm'},
      {"uid",        required_argument, NULL, 'u'},
      {"gid",        required_argument, NULL, 'g'},
      {"tmpfs-size", required_argument, NULL, 't'},
      {"hostname",   required_argument, NULL, 'H'},
      {0, 0, 0, 0}
    };

    int opt_idx;
    int c = getopt_long(sandbox_argc, sandbox_argv, "", long_options, &opt_idx);

    // End of options
    if( c == -1 )
      break;

    switch( c ) {
      case '?':
      case 'h':
        print_help();
        return 0;
      case 'v':
        verbose = 1;
        fprintf(stderr, "verbose sandbox enabled (running in ");
        switch (execution_mode) {
          case UNPRIVILEGED_CONTAINER_MODE:
            fprintf(stderr, "un");
          case PRIVILEGED_CONTAINER_MODE:
            fprintf(stderr, "privileged container");
            break;
        }
        fprintf(stderr, " mode)\n");
        break;
      case 'r': {
        sandbox_root = strdup(optarg);
        size_t sandbox_root_len = strlen(sandbox_root);
        if (sandbox_root[sandbox_root_len-1] == '/' ) {
            sandbox_root[sandbox_root_len-1] = '\0';
        }
        if (verbose) {
          fprintf(stderr, "Parsed --rootfs as \"%s\"\n", sandbox_root);
        }
      } break;
      case 'c':
        new_cd = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --cd as \"%s\"\n", new_cd);
        }
        break;
      case 'w':
      case 'm': {
        // Find the colon in "from:to"
        char *colon = strchr(optarg, ':');
        check(colon != NULL);

        // Extract "from" and "to"
        char *from = strndup(optarg, (colon - optarg));
        char *to = strdup(colon + 1);
        if ((from[0] != '/') && (strncmp(from, "9p/", 3) != 0)) {
          fprintf(stderr, "ERROR: Outside path \"%s\" must be absolute or 9p!  Ignoring...\n", from);
          break;
        }

        // Construct `map_list` object for this `from:to` pair
        struct map_list *entry = (struct map_list *) malloc(sizeof(struct map_list));
        entry->map_path = to;
        entry->outside_path = from;

        // If this was `--map`, then add it to `maps`, if it was `--workspace` add it to `workspaces`
        if (c == 'm') {
          entry->prev = maps;
          maps = entry;
        } else {
          entry->prev = workspaces;
          workspaces = entry;
        }
        if (verbose) {
          fprintf(stderr, "Parsed --%s as \"%s\" -> \"%s\"\n", c == 'm' ? "map" : "workspace",
                  entry->outside_path, entry->map_path);
        }
      } break;
      case 'p':
        persist_dir = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --persist as \"%s\"\n", persist_dir);
        }
        break;
      case 'u':
        dst_uid = atoi(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --uid as \"%d\"\n", dst_uid);
        }
        break;
      case 'g':
        dst_gid = atoi(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --gid as \"%d\"\n", dst_gid);
        }
        break;
      case 'e':
        entrypoint = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --entrypoint as \"%s\"\n", entrypoint);
        }
        break;
      case 't':
        tmpfs_size = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --tmpfs-size as \"%s\"\n", tmpfs_size);
        }
        break;
      case 'H':
        hostname = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --hostname as \"%s\"\n", hostname);
        }
        break;
      default:
        fputs("getoptlong defaulted?!\n", stderr);
        return 1;
    }
  }

  // Skip past those arguments
  sandbox_argv += optind;
  sandbox_argc -= optind;

  // If we were given an entrypoint, push that onto the front of `sandbox_argv`
  if (entrypoint != NULL) {
    // Yes, we clobber sandbox_argv[-1] here; but we already know that `optind` >= 2
    // since `entrypoint != NULL`, so this is acceptable.
    sandbox_argv -= 1;
    sandbox_argc += 1;
    sandbox_argv[0] = entrypoint;
  }

  // If we don't have a command, die
  if (sandbox_argc == 0) {
    fputs("No <cmd> given!\n", stderr);
    print_help();
    return 1;
  }

  // If we haven't been given a sandbox root, die
  if (!sandbox_root) {
    fputs("--rootfs is required!\n", stderr);
    print_help();
    return 1;
  }

  // If we're running in one of the container modes, we're going to syscall() ourselves a
  // new, cloned process that is in a container process. We will use a pipe for synchronization.
  // The regular SIGSTOP method does not work because container-inits don't receive STOP or KILL
  // signals from within their own pid namespace.
  int child_pipe[2], parent_pipe[2];
  check(0 == pipe(child_pipe));
  check(0 == pipe(parent_pipe));

  if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
    // We dissociate ourselves from the typical mount namespace.  This gives us the freedom
    // to start mounting things willy-nilly without mucking up the user's computer.
    check(0 == unshare(CLONE_NEWNS));

    // Even if we unshare, we might need to mark `/` as private, as systemd often subverts
    // the kernel's default value of `MS_PRIVATE` on the root mount.  This doesn't effect
    // the main root mount, because we have unshared, but this prevents our changes to
    // any subtrees of `/` (e.g. everything) from propagating back to the outside `/`.
    check(0 == mount(NULL, "/", NULL, MS_PRIVATE|MS_REC, NULL));

    // Mount the rootfs, shards, and workspace.  We do this here because, on this machine,
    // we may not have permissions to mount overlayfs within user namespaces.
    mount_the_world(sandbox_root, maps, workspaces, uid, gid, persist_dir, tmpfs_size);
  }

  // We want to request a new PID space, a new mount space, and a new user space
  int clone_flags = CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUSER | CLONE_NEWUTS | SIGCHLD;
  if ((child_pid = syscall(SYS_clone, clone_flags, 0, 0, 0, 0)) == 0) {
    // If we're in here, we have become the "child" process, within the container.

    // Get rid of the ends of the synchronization pipe that I'm not going to use
    close(child_pipe[1]);
    close(parent_pipe[0]);

    // N.B: Capabilities in the original user namespaces are now dropped
    // The kernel may have decided to reset our dumpability, because of
    // the privilege change. However, the parent needs to access our /proc
    // entries (undumpable processes have /proc/%pid owned by root) in order
    // to configure the sandbox, so reset dumpability.
    prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);

    // Tell the parent we're ready, and wait until it signals that it's done
    // setting up our PID/GID mapping in configure_user_namespace()
    check(1 == write(parent_pipe[1], "X", 1));
    char buff = 0;
    check(sizeof(char) == read(child_pipe[0], (void *)&buff, sizeof(char)));

    if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
      // If we are in privileged container mode, let's go ahead and drop back
      // to the original calling user's UID and GID, which has been mapped to
      // the requested uid/gids (defaulting to zero) within this container.
      check(0 == setuid(dst_uid));
      check(0 == setgid(dst_gid));

      // The /proc mountpoint previously mounted is in the wrong PID namespace;
      // mount a new procfs over it to to get better values:
      mount_procfs(sandbox_root, dst_uid, dst_gid);
    } else if (execution_mode == UNPRIVILEGED_CONTAINER_MODE) {
      // If we're in unprivileged container mode, mount the world now that we
      // have supreme cosmic power.
      mount_the_world(sandbox_root, maps, workspaces, dst_uid, dst_gid, persist_dir, tmpfs_size);
    }

    // Set the hostname, if that's been requested
    if (hostname != NULL) {
        check(sethostname(hostname, strlen(hostname)) == 0);
    }

    // Finally, we begin invocation of the target program.
    return sandbox_main(sandbox_root, new_cd, sandbox_argc, sandbox_argv, parent_pipe);
  }

  // If we're out here, we are still the "parent" process.  The Prestige lives on.

  // Check to make sure that the clone actually worked
  check(child_pid != -1);

  // We want to pass signals through to our child PID
  setup_signal_forwarding();

  // Get rid of the ends of the synchronization pipe that I'm not going to use.
  close(child_pipe[0]);
  close(parent_pipe[1]);

  // Wait until the child is ready to be configured.
  char buff = 0;
  check(sizeof(char) == read(parent_pipe[0], (void *)&buff, sizeof(char)));
  if (verbose) {
    fprintf(stderr, "Child Process PID is %d\n", child_pid);
  }

  // Configure user namespace for the child PID.
  configure_user_namespace(child_pid, uid, gid, dst_uid, dst_gid);

  // Signal to the child that it can now continue running.
  check(1 == write(child_pipe[1], "X", 1));

  // Wait until the child exits.
  check(child_pid == waitpid(child_pid, &status, 0));

  // Receive termination signal
  unsigned int child_exit_code = 0;
  check(sizeof(unsigned int) == read(parent_pipe[0], (void *)&child_exit_code, sizeof(unsigned int)));

  // Give back the terminal to the parent
  signal(SIGTTOU, SIG_IGN);
  tcsetpgrp(0, pgrp);

  // The child sandbox should alway exit cleanly, with a zero exit status.
  // The sandboxed executable's exit value will be reported via the pipes
  check(WIFEXITED(status));
  check(WEXITSTATUS(status) == 0);

  // We encode signal death as 256 + signal
  if (child_exit_code >= 256) {
    int child_signal = child_exit_code - 256;
    if (verbose) {
      fprintf(stderr, "Child Process %d signaled %d\n", child_pid, child_signal);
    }

    // Kill ourselves with the same signal
    signal(child_signal, SIG_DFL);
    check(raise(child_signal));
  } else {
    if (verbose) {
      fprintf(stderr, "Child Process %d exited with code %d\n", child_pid, child_exit_code);
    }
    return child_exit_code;
  }
}
