#include <stdint.h>
#include <stddef.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// OS CSPRNG only. No time-based seed or deterministic fallback.
int randombytes(uint8_t* out, size_t size) {
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t done = 0;
    while (done < size) {
        ssize_t n = read(fd, out + done, size - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return -1; }
        done += static_cast<size_t>(n);
    }
    close(fd);
    return 0;
}
