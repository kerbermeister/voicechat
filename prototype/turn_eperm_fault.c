/* Fixture only. The production image never includes or loads this library. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static ssize_t (*real_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static atomic_uint dropped;
static int persistent;

static void initialize(void) {
  real_sendto = dlsym(RTLD_NEXT, "sendto");
  if (!real_sendto) _exit(127);
  const char *mode = getenv("VOICECHAT_TEST_EPERM_MODE");
  persistent = mode && strcmp(mode, "persistent") == 0;
  const char loaded[] = "VOICECHAT_TEST_FAULT_LOADED\n";
  (void)write(STDERR_FILENO, loaded, sizeof(loaded) - 1);
}

ssize_t sendto(int fd, const void *buffer, size_t length, int flags,
               const struct sockaddr *destination, socklen_t address_length) {
  pthread_once(&initialized, initialize);
  const char marker[] = "vc-eperm-drop";
  if (buffer && length >= sizeof(marker) - 1 &&
      memcmp(buffer, marker, sizeof(marker) - 1) == 0) {
    unsigned count = atomic_fetch_add(&dropped, 1);
    if (persistent || count == 0) {
      if (count == 0) {
        const char injected[] = "VOICECHAT_TEST_EPERM_INJECTED\n";
        (void)write(STDERR_FILENO, injected, sizeof(injected) - 1);
      }
      errno = EPERM;
      return -1;
    }
  }
  return real_sendto(fd, buffer, length, flags, destination, address_length);
}
