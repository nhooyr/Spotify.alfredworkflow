#ifndef BUILD_ID
#define BUILD_ID "development"
#endif

#include <stddef.h>
#include <stdint.h>
const char *spotify_build_identifier(void);
size_t spotify_gzip_decode(void *destination, size_t capacity,
                           const void *source, size_t size);
size_t spotify_zstd_size(const void *source, size_t size);
size_t spotify_zstd_decode(void *destination, size_t capacity,
                           const void *source, size_t size);
uint32_t spotify_crc32(const void *source, size_t size);
