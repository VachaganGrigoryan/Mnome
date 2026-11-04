#ifndef MNOME_H
#define MNOME_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint8_t *ptr; size_t len; } MnomeBuffer;
/* ABI version 1. Input is borrowed for the duration of this call.
 * Output must be released exactly once with mnome_free, never libc free. */
MnomeBuffer mnome_request(const uint8_t *input, size_t len);
void mnome_free(MnomeBuffer buffer);
#endif
