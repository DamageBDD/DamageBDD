#ifndef DAMAGE_SECURE_PORT_PROTOCOL_H
#define DAMAGE_SECURE_PORT_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define DAMAGE_FRAME_UNLOCK_REQUEST 0x01u
#define DAMAGE_FRAME_OPERATION_REQUEST 0x02u
#define DAMAGE_FRAME_UNLOCK_RESPONSE 0x81u
#define DAMAGE_FRAME_OPERATION_RESPONSE 0x82u
#define DAMAGE_FRAME_STATUS_OK 0x00u
#define DAMAGE_FRAME_STATUS_ERROR 0x01u

/*
 * Reads/writes Erlang {packet,4} frames. A successful read allocates *payload;
 * the caller must securely clear sensitive payloads before free().
 */
int damage_read_packet4(int fd, uint8_t **payload, uint32_t *payload_len,
                        uint32_t max_payload_len);
int damage_write_packet4(int fd, const uint8_t *payload, uint32_t payload_len);

/* Non-optimisable zeroing primitive for temporary secret buffers. */
void damage_secure_zero(void *buffer, size_t length);

#endif
