#ifndef TG_CRYPTO_H
#define TG_CRYPTO_H
/* SHA-1/256/512, HMAC, PBKDF2, AES-256 (IGE), inflate/gzip, rozkład pq, losowe bajty. Bez zależności od systemu. */
#include <stdint.h>
#include <stddef.h>

typedef struct { uint32_t h[5]; uint64_t len; uint8_t buf[64]; int fill; } tg_sha1_ctx;
typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; int fill; } tg_sha256_ctx;
typedef struct { uint64_t h[8]; uint64_t len; uint8_t buf[128]; int fill; } tg_sha512_ctx;

void tg_sha1_init(tg_sha1_ctx *c);
void tg_sha1_update(tg_sha1_ctx *c, const void *d, size_t n);
void tg_sha1_final(tg_sha1_ctx *c, uint8_t out[20]);
void tg_sha1(const void *d, size_t n, uint8_t out[20]);

void tg_sha256_init(tg_sha256_ctx *c);
void tg_sha256_update(tg_sha256_ctx *c, const void *d, size_t n);
void tg_sha256_final(tg_sha256_ctx *c, uint8_t out[32]);
void tg_sha256(const void *d, size_t n, uint8_t out[32]);

void tg_sha512_init(tg_sha512_ctx *c);
void tg_sha512_update(tg_sha512_ctx *c, const void *d, size_t n);
void tg_sha512_final(tg_sha512_ctx *c, uint8_t out[64]);

void tg_pbkdf2_sha512(const uint8_t *pass, size_t plen, const uint8_t *salt, size_t slen, uint32_t iter, uint8_t out[64]);

/* AES-256; klucz 32 B */
typedef struct { uint8_t rk[240]; } tg_aes;
void tg_aes_set_key(tg_aes *a, const uint8_t key[32]);
void tg_aes_encrypt_block(const tg_aes *a, const uint8_t in[16], uint8_t out[16]);
void tg_aes_decrypt_block(const tg_aes *a, const uint8_t in[16], uint8_t out[16]);
/* IGE: iv = 32 B (pierwsze 16 = poprzedni szyfrogram, drugie 16 = poprzedni tekst jawny); len wielokrotność 16; in==out dozwolone */
void tg_aes_ige_encrypt(const uint8_t key[32], const uint8_t iv[32], const uint8_t *in, uint8_t *out, size_t len);
void tg_aes_ige_decrypt(const uint8_t key[32], const uint8_t iv[32], const uint8_t *in, uint8_t *out, size_t len);

/* inflate: zwraca 0 przy sukcesie, *out z malloc */
int tg_inflate_raw(const uint8_t *in, size_t inlen, uint8_t **out, size_t *outlen);
int tg_gunzip(const uint8_t *in, size_t inlen, uint8_t **out, size_t *outlen);

/* pq (<2^63) = p*q, p<q; 0 gdy się nie udało */
int tg_factor_pq(uint64_t pq, uint32_t *p, uint32_t *q);

void tg_random(void *buf, size_t n);

uint32_t tg_crc32(const uint8_t *d, size_t n);

#endif
