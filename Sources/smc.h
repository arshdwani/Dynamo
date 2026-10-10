#ifndef DYNAMO_SMC_H
#define DYNAMO_SMC_H

#include <stdint.h>

// Minimal AppleSMC access. Reading works as any user; writing requires root.
// All functions return 0 on success, non-zero on failure.

int smc_open(void);
void smc_close(void);

// Reads a key. On success *size holds the byte count and type receives the
// 4-char data type (null-terminated, needs 5 bytes).
int smc_read(const char *key, uint8_t *out, uint32_t *size, char *type);

// Writes `size` bytes to a key. Size must match the key's declared size.
int smc_write(const char *key, const uint8_t *data, uint32_t size);

#endif
