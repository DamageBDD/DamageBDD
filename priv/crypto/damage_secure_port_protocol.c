#include "damage_secure_port_protocol.h"

#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

static int read_exact(int fd, uint8_t *buffer, size_t length) {
    size_t offset = 0;

    while (offset < length) {
        ssize_t count = read(fd, buffer + offset, length - offset);
        if (count == 0) {
            return -1;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        offset += (size_t)count;
    }

    return 0;
}

static int write_exact(int fd, const uint8_t *buffer, size_t length) {
    size_t offset = 0;

    while (offset < length) {
        ssize_t count = write(fd, buffer + offset, length - offset);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        offset += (size_t)count;
    }

    return 0;
}

int damage_read_packet4(int fd, uint8_t **payload, uint32_t *payload_len,
                        uint32_t max_payload_len) {
    uint8_t header[4];
    uint32_t length;
    uint8_t *frame;

    if (payload == NULL || payload_len == NULL || max_payload_len == 0) {
        return -1;
    }

    *payload = NULL;
    *payload_len = 0;

    if (read_exact(fd, header, sizeof(header)) != 0) {
        return -1;
    }

    length = ((uint32_t)header[0] << 24) |
             ((uint32_t)header[1] << 16) |
             ((uint32_t)header[2] << 8) |
             (uint32_t)header[3];

    if (length == 0 || length > max_payload_len) {
        return -1;
    }

    frame = malloc(length);
    if (frame == NULL) {
        return -1;
    }

    if (read_exact(fd, frame, length) != 0) {
        damage_secure_zero(frame, length);
        free(frame);
        return -1;
    }

    *payload = frame;
    *payload_len = length;
    return 0;
}

int damage_write_packet4(int fd, const uint8_t *payload, uint32_t payload_len) {
    uint8_t header[4];

    if (payload == NULL || payload_len == 0) {
        return -1;
    }

    header[0] = (uint8_t)((payload_len >> 24) & 0xffu);
    header[1] = (uint8_t)((payload_len >> 16) & 0xffu);
    header[2] = (uint8_t)((payload_len >> 8) & 0xffu);
    header[3] = (uint8_t)(payload_len & 0xffu);

    if (write_exact(fd, header, sizeof(header)) != 0) {
        return -1;
    }

    return write_exact(fd, payload, payload_len);
}

void damage_secure_zero(void *buffer, size_t length) {
    volatile uint8_t *cursor = (volatile uint8_t *)buffer;

    if (cursor == NULL) {
        return;
    }

    while (length > 0) {
        *cursor++ = 0;
        --length;
    }
}
