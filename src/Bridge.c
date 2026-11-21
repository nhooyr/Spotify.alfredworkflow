#include "Bridge.h"
#include <zlib.h>
extern size_t ZSTD_decompress(void *, size_t, const void *, size_t);
extern unsigned long long ZSTD_getFrameContentSize(const void *, size_t);
extern unsigned ZSTD_isError(size_t);
const char *spotify_build_identifier(void) { return BUILD_ID; }

size_t spotify_gzip_decode(void *destination, size_t capacity,
                           const void *source, size_t size) {
  z_stream stream = {0};
  stream.next_in = (Bytef *)source;
  stream.avail_in = (uInt)size;
  stream.next_out = destination;
  stream.avail_out = (uInt)capacity;
  if (inflateInit2(&stream, 15 + 32) != Z_OK)
    return 0;
  int result = inflate(&stream, Z_FINISH);
  size_t written = stream.total_out;
  inflateEnd(&stream);
  return result == Z_STREAM_END ? written : 0;
}
size_t spotify_zstd_size(const void *source, size_t size) {
  unsigned long long value = ZSTD_getFrameContentSize(source, size);
  return value <= 8 * 1024 * 1024 ? (size_t)value : 0;
}
size_t spotify_zstd_decode(void *destination, size_t capacity,
                           const void *source, size_t size) {
  size_t result = ZSTD_decompress(destination, capacity, source, size);
  return ZSTD_isError(result) ? 0 : result;
}
uint32_t spotify_crc32(const void *source, size_t size) {
  return (uint32_t)crc32(0, source, (uInt)size);
}
