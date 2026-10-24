#ifndef NOCHE_ADBLOCK_H
#define NOCHE_ADBLOCK_H
#include <stddef.h>
#include <stdint.h>

/* Engine is immutable after creation. Built with default features it is Send+Sync:
   nab_check / nab_cosmetic may be called concurrently on one engine. */

/* lists: n NUL-terminated UTF-8 filter list texts (ABP syntax). Never NULL. */
void *nab_engine_new(const char *const *lists, size_t n);
void  nab_engine_free(void *e);

/* 1 = block, 0 = allow (also 0 for unparseable URLs). request_type: "script", "image",
   "stylesheet", "xmlhttprequest", "sub_frame", "main_frame", "font", "media", "ping", "other". */
int   nab_check(const void *e, const char *url, const char *source_url, const char *request_type);

/* JSON {"hide":[...],"procedural":[...],"exceptions":[...],"script":"...","generichide":bool}.
   Free with nab_string_free. NULL on failure. */
char *nab_cosmetic(const void *e, const char *url);
void  nab_string_free(char *s);

/* Serialized engine buffer owned by Rust: free with nab_bytes_free(ptr, len). */
uint8_t *nab_serialize(const void *e, size_t *out_len);
void     nab_bytes_free(uint8_t *p, size_t len);
/* NULL if the buffer is invalid or from an incompatible crate version. */
void *nab_deserialize(const uint8_t *buf, size_t len);
#endif
