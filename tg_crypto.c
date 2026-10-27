#include "tg_crypto.h"
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#include "tg_consts.inc"

#define ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define ROL32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))
#define ROR64(x, n) (((x) >> (n)) | ((x) << (64 - (n))))

/* ---------------- SHA-1 ---------------- */

static void sha1_block(tg_sha1_ctx *c, const uint8_t *p)
{
    uint32_t w[80];
    for (int i = 0; i < 16; i++) w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) | ((uint32_t)p[i * 4 + 2] << 8) | p[i * 4 + 3];
    for (int i = 16; i < 80; i++) w[i] = ROL32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3], e = c->h[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20) { f = (b & cc) | (~b & d); k = 0x5a827999u; }
        else if (i < 40) { f = b ^ cc ^ d; k = 0x6ed9eba1u; }
        else if (i < 60) { f = (b & cc) | (b & d) | (cc & d); k = 0x8f1bbcdcu; }
        else { f = b ^ cc ^ d; k = 0xca62c1d6u; }
        uint32_t t = ROL32(a, 5) + f + e + k + w[i];
        e = d; d = cc; cc = ROL32(b, 30); b = a; a = t;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d; c->h[4] += e;
}

void tg_sha1_init(tg_sha1_ctx *c)
{
    c->h[0] = 0x67452301u; c->h[1] = 0xefcdab89u; c->h[2] = 0x98badcfeu; c->h[3] = 0x10325476u; c->h[4] = 0xc3d2e1f0u;
    c->len = 0; c->fill = 0;
}

void tg_sha1_update(tg_sha1_ctx *c, const void *d, size_t n)
{
    const uint8_t *p = (const uint8_t *)d;
    c->len += n;
    while (n) {
        int take = 64 - c->fill;
        if ((size_t)take > n) take = (int)n;
        memcpy(c->buf + c->fill, p, (size_t)take);
        c->fill += take; p += take; n -= (size_t)take;
        if (c->fill == 64) { sha1_block(c, c->buf); c->fill = 0; }
    }
}

void tg_sha1_final(tg_sha1_ctx *c, uint8_t out[20])
{
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    tg_sha1_update(c, &pad, 1);
    pad = 0;
    while (c->fill != 56) tg_sha1_update(c, &pad, 1);
    uint8_t lb[8];
    for (int i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    tg_sha1_update(c, lb, 8);
    for (int i = 0; i < 5; i++) { out[i * 4] = (uint8_t)(c->h[i] >> 24); out[i * 4 + 1] = (uint8_t)(c->h[i] >> 16); out[i * 4 + 2] = (uint8_t)(c->h[i] >> 8); out[i * 4 + 3] = (uint8_t)c->h[i]; }
}

void tg_sha1(const void *d, size_t n, uint8_t out[20])
{
    tg_sha1_ctx c;
    tg_sha1_init(&c);
    tg_sha1_update(&c, d, n);
    tg_sha1_final(&c, out);
}

/* ---------------- SHA-256 ---------------- */

static void sha256_block(tg_sha256_ctx *c, const uint8_t *p)
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++) w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) | ((uint32_t)p[i * 4 + 2] << 8) | p[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR32(w[i - 15], 7) ^ ROR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR32(w[i - 2], 17) ^ ROR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3], e = c->h[4], f = c->h[5], g = c->h[6], h = c->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ROR32(e, 6) ^ ROR32(e, 11) ^ ROR32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + K256[i] + w[i];
        uint32_t S0 = ROR32(a, 2) ^ ROR32(a, 13) ^ ROR32(a, 22);
        uint32_t mj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = S0 + mj;
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d; c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

void tg_sha256_init(tg_sha256_ctx *c)
{
    for (int i = 0; i < 8; i++) c->h[i] = H256[i];
    c->len = 0; c->fill = 0;
}

void tg_sha256_update(tg_sha256_ctx *c, const void *d, size_t n)
{
    const uint8_t *p = (const uint8_t *)d;
    c->len += n;
    while (n) {
        int take = 64 - c->fill;
        if ((size_t)take > n) take = (int)n;
        memcpy(c->buf + c->fill, p, (size_t)take);
        c->fill += take; p += take; n -= (size_t)take;
        if (c->fill == 64) { sha256_block(c, c->buf); c->fill = 0; }
    }
}

void tg_sha256_final(tg_sha256_ctx *c, uint8_t out[32])
{
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    tg_sha256_update(c, &pad, 1);
    pad = 0;
    while (c->fill != 56) tg_sha256_update(c, &pad, 1);
    uint8_t lb[8];
    for (int i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    tg_sha256_update(c, lb, 8);
    for (int i = 0; i < 8; i++) { out[i * 4] = (uint8_t)(c->h[i] >> 24); out[i * 4 + 1] = (uint8_t)(c->h[i] >> 16); out[i * 4 + 2] = (uint8_t)(c->h[i] >> 8); out[i * 4 + 3] = (uint8_t)c->h[i]; }
}

void tg_sha256(const void *d, size_t n, uint8_t out[32])
{
    tg_sha256_ctx c;
    tg_sha256_init(&c);
    tg_sha256_update(&c, d, n);
    tg_sha256_final(&c, out);
}

/* ---------------- SHA-512 ---------------- */

static void sha512_block(tg_sha512_ctx *c, const uint8_t *p)
{
    uint64_t w[80];
    for (int i = 0; i < 16; i++) {
        uint64_t v = 0;
        for (int j = 0; j < 8; j++) v = (v << 8) | p[i * 8 + j];
        w[i] = v;
    }
    for (int i = 16; i < 80; i++) {
        uint64_t s0 = ROR64(w[i - 15], 1) ^ ROR64(w[i - 15], 8) ^ (w[i - 15] >> 7);
        uint64_t s1 = ROR64(w[i - 2], 19) ^ ROR64(w[i - 2], 61) ^ (w[i - 2] >> 6);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint64_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3], e = c->h[4], f = c->h[5], g = c->h[6], h = c->h[7];
    for (int i = 0; i < 80; i++) {
        uint64_t S1 = ROR64(e, 14) ^ ROR64(e, 18) ^ ROR64(e, 41);
        uint64_t ch = (e & f) ^ (~e & g);
        uint64_t t1 = h + S1 + ch + K512[i] + w[i];
        uint64_t S0 = ROR64(a, 28) ^ ROR64(a, 34) ^ ROR64(a, 39);
        uint64_t mj = (a & b) ^ (a & cc) ^ (b & cc);
        uint64_t t2 = S0 + mj;
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d; c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

void tg_sha512_init(tg_sha512_ctx *c)
{
    for (int i = 0; i < 8; i++) c->h[i] = H512[i];
    c->len = 0; c->fill = 0;
}

void tg_sha512_update(tg_sha512_ctx *c, const void *d, size_t n)
{
    const uint8_t *p = (const uint8_t *)d;
    c->len += n;
    while (n) {
        int take = 128 - c->fill;
        if ((size_t)take > n) take = (int)n;
        memcpy(c->buf + c->fill, p, (size_t)take);
        c->fill += take; p += take; n -= (size_t)take;
        if (c->fill == 128) { sha512_block(c, c->buf); c->fill = 0; }
    }
}

void tg_sha512_final(tg_sha512_ctx *c, uint8_t out[64])
{
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    tg_sha512_update(c, &pad, 1);
    pad = 0;
    while (c->fill != 112) tg_sha512_update(c, &pad, 1);
    uint8_t lb[16];
    for (int i = 0; i < 8; i++) lb[i] = 0;
    for (int i = 0; i < 8; i++) lb[8 + i] = (uint8_t)(bits >> (56 - 8 * i));
    tg_sha512_update(c, lb, 16);
    for (int i = 0; i < 8; i++) for (int j = 0; j < 8; j++) out[i * 8 + j] = (uint8_t)(c->h[i] >> (56 - 8 * j));
}

/* PBKDF2-HMAC-SHA512 z jednym blokiem wyjścia (64 B) */
void tg_pbkdf2_sha512(const uint8_t *pass, size_t plen, const uint8_t *salt, size_t slen, uint32_t iter, uint8_t out[64])
{
    uint8_t k[128];
    memset(k, 0, 128);
    if (plen > 128) { tg_sha512_ctx t; tg_sha512_init(&t); tg_sha512_update(&t, pass, plen); tg_sha512_final(&t, k); }
    else memcpy(k, pass, plen);
    uint8_t ipad[128], opad[128];
    for (int i = 0; i < 128; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    tg_sha512_ctx istate, ostate;
    tg_sha512_init(&istate); tg_sha512_update(&istate, ipad, 128);
    tg_sha512_init(&ostate); tg_sha512_update(&ostate, opad, 128);
    uint8_t u[64], t[64], blk[4] = { 0, 0, 0, 1 };
    tg_sha512_ctx c = istate;
    tg_sha512_update(&c, salt, slen);
    tg_sha512_update(&c, blk, 4);
    tg_sha512_final(&c, u);
    c = ostate; tg_sha512_update(&c, u, 64); tg_sha512_final(&c, u);
    memcpy(t, u, 64);
    for (uint32_t i = 1; i < iter; i++) {
        c = istate; tg_sha512_update(&c, u, 64); tg_sha512_final(&c, u);
        c = ostate; tg_sha512_update(&c, u, 64); tg_sha512_final(&c, u);
        for (int j = 0; j < 64; j++) t[j] ^= u[j];
    }
    memcpy(out, t, 64);
}

/* ---------------- AES-256 ---------------- */

static uint8_t SBOX[256], ISBOX[256];
static int aes_ready = 0;

static uint8_t xtime(uint8_t x) { return (uint8_t)((x << 1) ^ ((x & 0x80) ? 0x1b : 0)); }

static uint8_t gmul(uint8_t a, uint8_t b)
{
    uint8_t r = 0;
    while (b) {
        if (b & 1) r ^= a;
        a = xtime(a);
        b >>= 1;
    }
    return r;
}

static void aes_init(void)
{
    if (aes_ready) return;
    /* S-box: odwrotność w GF(2^8) + przekształcenie afiniczne */
    uint8_t p = 1, q = 1;
    do {
        p = (uint8_t)(p ^ (p << 1) ^ ((p & 0x80) ? 0x1b : 0));      /* p *= 3 */
        q ^= (uint8_t)(q << 1); q ^= (uint8_t)(q << 2); q ^= (uint8_t)(q << 4);
        if (q & 0x80) q ^= 0x09;                                      /* q /= 3 */
        uint8_t r1 = (uint8_t)((q << 1) | (q >> 7)), r2 = (uint8_t)((q << 2) | (q >> 6)), r3 = (uint8_t)((q << 3) | (q >> 5)), r4 = (uint8_t)((q << 4) | (q >> 4));
        uint8_t x = (uint8_t)(q ^ r1 ^ r2 ^ r3 ^ r4);
        SBOX[p] = (uint8_t)(x ^ 0x63);
    } while (p != 1);
    SBOX[0] = 0x63;
    for (int i = 0; i < 256; i++) ISBOX[SBOX[i]] = (uint8_t)i;
    aes_ready = 1;
}

void tg_aes_set_key(tg_aes *a, const uint8_t key[32])
{
    aes_init();
    memcpy(a->rk, key, 32);
    uint8_t rcon = 1;
    for (int i = 8; i < 60; i++) {
        uint8_t t[4];
        memcpy(t, a->rk + (i - 1) * 4, 4);
        if ((i & 7) == 0) {
            uint8_t u = t[0];
            t[0] = (uint8_t)(SBOX[t[1]] ^ rcon); t[1] = SBOX[t[2]]; t[2] = SBOX[t[3]]; t[3] = SBOX[u];
            rcon = xtime(rcon);
        } else if ((i & 7) == 4) {
            for (int j = 0; j < 4; j++) t[j] = SBOX[t[j]];
        }
        for (int j = 0; j < 4; j++) a->rk[i * 4 + j] = (uint8_t)(a->rk[(i - 8) * 4 + j] ^ t[j]);
    }
}

static void add_round_key(uint8_t *s, const uint8_t *rk) { for (int i = 0; i < 16; i++) s[i] ^= rk[i]; }

void tg_aes_encrypt_block(const tg_aes *a, const uint8_t in[16], uint8_t out[16])
{
    uint8_t s[16], t[16];
    memcpy(s, in, 16);
    add_round_key(s, a->rk);
    for (int round = 1; round <= 14; round++) {
        for (int i = 0; i < 16; i++) s[i] = SBOX[s[i]];
        /* ShiftRows (stan kolumnami: s[4*c + r]) */
        for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) t[4 * c + r] = s[4 * ((c + r) & 3) + r];
        if (round != 14) {
            for (int c = 0; c < 4; c++) {
                uint8_t *col = t + 4 * c;
                uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3];
                uint8_t all = (uint8_t)(a0 ^ a1 ^ a2 ^ a3);
                s[4 * c + 0] = (uint8_t)(a0 ^ all ^ xtime((uint8_t)(a0 ^ a1)));
                s[4 * c + 1] = (uint8_t)(a1 ^ all ^ xtime((uint8_t)(a1 ^ a2)));
                s[4 * c + 2] = (uint8_t)(a2 ^ all ^ xtime((uint8_t)(a2 ^ a3)));
                s[4 * c + 3] = (uint8_t)(a3 ^ all ^ xtime((uint8_t)(a3 ^ a0)));
            }
        } else {
            memcpy(s, t, 16);
        }
        add_round_key(s, a->rk + 16 * round);
    }
    memcpy(out, s, 16);
}

void tg_aes_decrypt_block(const tg_aes *a, const uint8_t in[16], uint8_t out[16])
{
    uint8_t s[16], t[16];
    memcpy(s, in, 16);
    add_round_key(s, a->rk + 16 * 14);
    for (int round = 13; round >= 0; round--) {
        /* InvShiftRows */
        for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) t[4 * ((c + r) & 3) + r] = s[4 * c + r];
        for (int i = 0; i < 16; i++) t[i] = ISBOX[t[i]];
        add_round_key(t, a->rk + 16 * round);
        if (round != 0) {
            for (int c = 0; c < 4; c++) {
                uint8_t a0 = t[4 * c], a1 = t[4 * c + 1], a2 = t[4 * c + 2], a3 = t[4 * c + 3];
                s[4 * c + 0] = (uint8_t)(gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9));
                s[4 * c + 1] = (uint8_t)(gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13));
                s[4 * c + 2] = (uint8_t)(gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11));
                s[4 * c + 3] = (uint8_t)(gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14));
            }
        } else {
            memcpy(s, t, 16);
        }
    }
    memcpy(out, s, 16);
}

void tg_aes_ige_encrypt(const uint8_t key[32], const uint8_t iv[32], const uint8_t *in, uint8_t *out, size_t len)
{
    tg_aes a;
    tg_aes_set_key(&a, key);
    uint8_t y[16], x[16], t[16];
    memcpy(y, iv, 16);
    memcpy(x, iv + 16, 16);
    for (size_t off = 0; off + 16 <= len; off += 16) {
        uint8_t cur[16];
        memcpy(cur, in + off, 16);
        for (int i = 0; i < 16; i++) t[i] = (uint8_t)(cur[i] ^ y[i]);
        tg_aes_encrypt_block(&a, t, t);
        for (int i = 0; i < 16; i++) y[i] = (uint8_t)(t[i] ^ x[i]);
        memcpy(x, cur, 16);
        memcpy(out + off, y, 16);
    }
}

void tg_aes_ige_decrypt(const uint8_t key[32], const uint8_t iv[32], const uint8_t *in, uint8_t *out, size_t len)
{
    tg_aes a;
    tg_aes_set_key(&a, key);
    uint8_t y[16], x[16], t[16];
    memcpy(y, iv, 16);
    memcpy(x, iv + 16, 16);
    for (size_t off = 0; off + 16 <= len; off += 16) {
        uint8_t cur[16];
        memcpy(cur, in + off, 16);
        for (int i = 0; i < 16; i++) t[i] = (uint8_t)(cur[i] ^ x[i]);
        tg_aes_decrypt_block(&a, t, t);
        for (int i = 0; i < 16; i++) x[i] = (uint8_t)(t[i] ^ y[i]);
        memcpy(y, cur, 16);
        memcpy(out + off, x, 16);
    }
}

/* ---------------- inflate (wg. zasady działania puff.c) ---------------- */

#define MAXBITS 15
#define FIXLCODES 288

typedef struct {
    const uint8_t *in; size_t inlen, incnt;
    uint32_t bitbuf; int bitcnt;
    uint8_t *out; size_t outcnt, outcap;
    int err;
} infl;

typedef struct { short count[MAXBITS + 1]; short symbol[FIXLCODES]; } huff;

static int ibits(infl *s, int need)
{
    uint32_t val = s->bitbuf;
    while (s->bitcnt < need) {
        if (s->incnt >= s->inlen) { s->err = 1; return 0; }
        val |= (uint32_t)s->in[s->incnt++] << s->bitcnt;
        s->bitcnt += 8;
    }
    s->bitbuf = val >> need;
    s->bitcnt -= need;
    return (int)(val & ((1u << need) - 1));
}

static int iemit(infl *s, uint8_t b)
{
    if (s->outcnt == s->outcap) {
        size_t ncap = s->outcap ? s->outcap * 2 : 4096;
        if (ncap > (64u << 20)) { s->err = 2; return 0; }
        uint8_t *n = (uint8_t *)realloc(s->out, ncap);
        if (!n) { s->err = 3; return 0; }
        s->out = n; s->outcap = ncap;
    }
    s->out[s->outcnt++] = b;
    return 1;
}

static int idecode(infl *s, const huff *h)
{
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= MAXBITS; len++) {
        code |= ibits(s, 1);
        if (s->err) return -1;
        int count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -10;
}

static int iconstruct(huff *h, const short *length, int n)
{
    short offs[MAXBITS + 1];
    for (int len = 0; len <= MAXBITS; len++) h->count[len] = 0;
    for (int sym = 0; sym < n; sym++) h->count[length[sym]]++;
    if (h->count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= MAXBITS; len++) {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return left;
    }
    offs[1] = 0;
    for (int len = 1; len < MAXBITS; len++) offs[len + 1] = (short)(offs[len] + h->count[len]);
    for (int sym = 0; sym < n; sym++) if (length[sym] != 0) h->symbol[offs[length[sym]]++] = (short)sym;
    return left;
}

static int icodes(infl *s, const huff *lencode, const huff *distcode)
{
    static const short lens[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    static const short lext[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    static const short dists[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
    static const short dext[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
    for (;;) {
        int symbol = idecode(s, lencode);
        if (symbol < 0) return -1;
        if (symbol < 256) {
            if (!iemit(s, (uint8_t)symbol)) return -1;
        } else if (symbol > 256) {
            symbol -= 257;
            if (symbol >= 29) return -2;
            int len = lens[symbol] + ibits(s, lext[symbol]);
            symbol = idecode(s, distcode);
            if (symbol < 0 || symbol >= 30) return -3;
            size_t dist = (size_t)(dists[symbol] + ibits(s, dext[symbol]));
            if (s->err) return -1;
            if (dist > s->outcnt) return -4;
            while (len--) {
                if (!iemit(s, s->out[s->outcnt - dist])) return -1;
            }
        } else {
            return 0;
        }
    }
}

static int istored(infl *s)
{
    s->bitbuf = 0; s->bitcnt = 0;
    if (s->incnt + 4 > s->inlen) return -1;
    unsigned len = s->in[s->incnt] | ((unsigned)s->in[s->incnt + 1] << 8);
    unsigned nlen = s->in[s->incnt + 2] | ((unsigned)s->in[s->incnt + 3] << 8);
    s->incnt += 4;
    if (len != (~nlen & 0xffffu)) return -2;
    if (s->incnt + len > s->inlen) return -1;
    while (len--) if (!iemit(s, s->in[s->incnt++])) return -1;
    return 0;
}

static int ifixed(infl *s)
{
    static huff lencode, distcode;
    static int built = 0;
    if (!built) {
        short lengths[FIXLCODES];
        int sym;
        for (sym = 0; sym < 144; sym++) lengths[sym] = 8;
        for (; sym < 256; sym++) lengths[sym] = 9;
        for (; sym < 280; sym++) lengths[sym] = 7;
        for (; sym < FIXLCODES; sym++) lengths[sym] = 8;
        iconstruct(&lencode, lengths, FIXLCODES);
        for (sym = 0; sym < 30; sym++) lengths[sym] = 5;
        iconstruct(&distcode, lengths, 30);
        built = 1;
    }
    return icodes(s, &lencode, &distcode);
}

static int idynamic(infl *s)
{
    static const short order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    short lengths[320];
    huff lencode, distcode;
    int nlen = ibits(s, 5) + 257;
    int ndist = ibits(s, 5) + 1;
    int ncode = ibits(s, 4) + 4;
    if (s->err) return -1;
    if (nlen > 286 || ndist > 30) return -3;
    int index;
    for (index = 0; index < ncode; index++) lengths[order[index]] = (short)ibits(s, 3);
    for (; index < 19; index++) lengths[order[index]] = 0;
    if (iconstruct(&lencode, lengths, 19) != 0) return -4;
    index = 0;
    while (index < nlen + ndist) {
        int symbol = idecode(s, &lencode);
        if (symbol < 0) return -5;
        if (symbol < 16) {
            lengths[index++] = (short)symbol;
        } else {
            int len = 0;
            if (symbol == 16) {
                if (index == 0) return -6;
                len = lengths[index - 1];
                symbol = 3 + ibits(s, 2);
            } else if (symbol == 17) {
                symbol = 3 + ibits(s, 3);
            } else {
                symbol = 11 + ibits(s, 7);
            }
            if (index + symbol > nlen + ndist) return -7;
            while (symbol--) lengths[index++] = (short)len;
        }
        if (s->err) return -1;
    }
    if (lengths[256] == 0) return -9;
    int err = iconstruct(&lencode, lengths, nlen);
    if (err && (err < 0 || nlen != lencode.count[0] + lencode.count[1])) return -7;
    err = iconstruct(&distcode, lengths + nlen, ndist);
    if (err && (err < 0 || ndist != distcode.count[0] + distcode.count[1])) return -8;
    return icodes(s, &lencode, &distcode);
}

int tg_inflate_raw(const uint8_t *in, size_t inlen, uint8_t **out, size_t *outlen)
{
    infl s;
    memset(&s, 0, sizeof(s));
    s.in = in; s.inlen = inlen;
    int last, err = 0;
    do {
        last = ibits(&s, 1);
        int type = ibits(&s, 2);
        if (s.err) { err = -1; break; }
        err = type == 0 ? istored(&s) : type == 1 ? ifixed(&s) : type == 2 ? idynamic(&s) : -1;
        if (err) break;
    } while (!last);
    if (err || s.err) { free(s.out); return -1; }
    *out = s.out ? s.out : (uint8_t *)malloc(1);
    *outlen = s.outcnt;
    return 0;
}

int tg_gunzip(const uint8_t *in, size_t inlen, uint8_t **out, size_t *outlen)
{
    if (inlen < 18 || in[0] != 0x1f || in[1] != 0x8b || in[2] != 8) return -1;
    int flg = in[3];
    size_t pos = 10;
    if (flg & 4) { if (pos + 2 > inlen) return -1; pos += 2 + (in[pos] | ((size_t)in[pos + 1] << 8)); }
    if (flg & 8) { while (pos < inlen && in[pos]) pos++; pos++; }
    if (flg & 16) { while (pos < inlen && in[pos]) pos++; pos++; }
    if (flg & 2) pos += 2;
    if (pos >= inlen) return -1;
    return tg_inflate_raw(in + pos, inlen - pos, out, outlen);
}

/* ---------------- rozkład pq (Pollard-Brent, bez dzielenia) ---------------- */

static uint64_t mulmod64(uint64_t a, uint64_t b, uint64_t m)
{
    uint64_t r = 0;
    while (b) {
        if (b & 1) { r += a; if (r >= m) r -= m; }
        a += a; if (a >= m) a -= m;
        b >>= 1;
    }
    return r;
}

static uint64_t gcd64(uint64_t a, uint64_t b)
{
    if (a == 0) return b;
    if (b == 0) return a;
    int shift = 0;
    while (((a | b) & 1) == 0) { a >>= 1; b >>= 1; shift++; }
    while ((a & 1) == 0) a >>= 1;
    do {
        while ((b & 1) == 0) b >>= 1;
        if (a > b) { uint64_t t = a; a = b; b = t; }
        b -= a;
    } while (b != 0);
    return a << shift;
}

static uint64_t absdiff(uint64_t a, uint64_t b) { return a > b ? a - b : b - a; }

int tg_factor_pq(uint64_t n, uint32_t *p, uint32_t *q)
{
    if (n < 4) return 0;
    if ((n & 1) == 0) { *p = 2; *q = (uint32_t)(n >> 1); return 1; }
    for (uint64_t c = 1; c < 40; c++) {
        uint64_t y = 2, x = 0, ys = 0, qq = 1, g = 1, r = 1;
        const uint64_t m = 128;
        do {
            x = y;
            for (uint64_t i = 0; i < r; i++) { y = mulmod64(y, y, n) + c; if (y >= n) y -= n; }
            uint64_t k = 0;
            do {
                ys = y;
                uint64_t lim = (r - k) < m ? (r - k) : m;
                for (uint64_t i = 0; i < lim; i++) {
                    y = mulmod64(y, y, n) + c; if (y >= n) y -= n;
                    qq = mulmod64(qq, absdiff(x, y), n);
                }
                g = gcd64(qq, n);
                k += m;
            } while (k < r && g == 1);
            r <<= 1;
        } while (g == 1 && r < ((uint64_t)1 << 40));
        if (g == n) {
            do {
                ys = mulmod64(ys, ys, n) + c; if (ys >= n) ys -= n;
                g = gcd64(absdiff(x, ys), n);
            } while (g == 1);
        }
        if (g != 1 && g != n) {
            uint64_t other = 0;
            /* other = n / g bez dzielenia: szukamy bitowo */
            uint64_t rem = n, d = g;
            int sh = 0;
            while ((d << 1) > d && (d << 1) <= rem) { d <<= 1; sh++; }
            for (; sh >= 0; sh--) {
                if (rem >= d) { rem -= d; other |= (uint64_t)1 << sh; }
                d >>= 1;
            }
            uint64_t a = g < other ? g : other, b = g < other ? other : g;
            *p = (uint32_t)a; *q = (uint32_t)b;
            return 1;
        }
    }
    return 0;
}

/* ---------------- losowe bajty, crc32 ---------------- */

void tg_random(void *buf, size_t n)
{
    int fd = open("/dev/urandom", O_RDONLY);
    size_t got = 0;
    if (fd >= 0) {
        while (got < n) {
            ssize_t r = read(fd, (uint8_t *)buf + got, n - got);
            if (r <= 0) break;
            got += (size_t)r;
        }
        close(fd);
    }
    if (got < n) {                      /* awaryjnie: słabe źródło (nie powinno się zdarzyć) */
        uint32_t x = 0x9e3779b9u ^ (uint32_t)(uintptr_t)buf;
        for (; got < n; got++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; ((uint8_t *)buf)[got] = (uint8_t)x; }
    }
}

uint32_t tg_crc32(const uint8_t *d, size_t n)
{
    uint32_t c = 0xffffffffu;
    for (size_t i = 0; i < n; i++) {
        c ^= d[i];
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (uint32_t)(0 - (c & 1)));
    }
    return ~c;
}
