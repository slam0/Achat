#include "tg_bn.h"

static void bn_norm(tg_bn *a)
{
    while (a->n > 0 && a->w[a->n - 1] == 0) a->n--;
}

void bn_zero(tg_bn *a)
{
    for (int i = 0; i < BN_MAX; i++) a->w[i] = 0;
    a->n = 0;
}

void bn_set_u32(tg_bn *a, uint32_t v)
{
    bn_zero(a);
    a->w[0] = v;
    a->n = v ? 1 : 0;
}

void bn_from_be(tg_bn *a, const uint8_t *b, size_t len)
{
    bn_zero(a);
    if (len > BN_MAX * 4) len = BN_MAX * 4;
    for (size_t i = 0; i < len; i++) {
        size_t pos = len - 1 - i;                    /* numer bajtu od końca */
        a->w[pos >> 2] |= (uint32_t)b[i] << ((pos & 3) * 8);
    }
    a->n = (int)((len + 3) >> 2);
    bn_norm(a);
}

int bn_to_be(const tg_bn *a, uint8_t *out, size_t len)
{
    int need = (bn_bits(a) + 7) >> 3;
    if ((size_t)need > len) return 0;
    for (size_t i = 0; i < len; i++) {
        size_t pos = len - 1 - i;
        size_t limb = pos >> 2;
        uint32_t v = limb < (size_t)a->n ? a->w[limb] : 0;
        out[i] = (uint8_t)(v >> ((pos & 3) * 8));
    }
    return 1;
}

int bn_bits(const tg_bn *a)
{
    if (a->n == 0) return 0;
    uint32_t top = a->w[a->n - 1];
    int b = 0;
    while (top) { b++; top >>= 1; }
    return (a->n - 1) * 32 + b;
}

int bn_cmp(const tg_bn *a, const tg_bn *b)
{
    if (a->n != b->n) return a->n > b->n ? 1 : -1;
    for (int i = a->n - 1; i >= 0; i--) {
        if (a->w[i] != b->w[i]) return a->w[i] > b->w[i] ? 1 : -1;
    }
    return 0;
}

void bn_add(tg_bn *r, const tg_bn *a, const tg_bn *b)
{
    int n = a->n > b->n ? a->n : b->n;
    uint64_t c = 0;
    for (int i = 0; i < n; i++) {
        uint64_t s = c + (i < a->n ? a->w[i] : 0) + (i < b->n ? b->w[i] : 0);
        r->w[i] = (uint32_t)s;
        c = s >> 32;
    }
    r->n = n;
    if (c && n < BN_MAX) { r->w[n] = (uint32_t)c; r->n = n + 1; }
    for (int i = r->n; i < BN_MAX; i++) r->w[i] = 0;
    bn_norm(r);
}

void bn_sub(tg_bn *r, const tg_bn *a, const tg_bn *b)
{
    int64_t borrow = 0;
    int n = a->n;
    for (int i = 0; i < n; i++) {
        int64_t d = (int64_t)a->w[i] - (i < b->n ? (int64_t)b->w[i] : 0) - borrow;
        if (d < 0) { d += ((int64_t)1 << 32); borrow = 1; } else borrow = 0;
        r->w[i] = (uint32_t)d;
    }
    r->n = n;
    for (int i = r->n; i < BN_MAX; i++) r->w[i] = 0;
    bn_norm(r);
}

void bn_mul(tg_bn *r, const tg_bn *a, const tg_bn *b)
{
    uint32_t t[BN_MAX];
    for (int i = 0; i < BN_MAX; i++) t[i] = 0;
    if (a->n + b->n > BN_MAX) { bn_zero(r); return; }
    for (int i = 0; i < a->n; i++) {
        uint64_t c = 0;
        for (int j = 0; j < b->n; j++) {
            uint64_t s = (uint64_t)t[i + j] + (uint64_t)a->w[i] * b->w[j] + c;
            t[i + j] = (uint32_t)s;
            c = s >> 32;
        }
        t[i + b->n] = (uint32_t)c;
    }
    for (int i = 0; i < BN_MAX; i++) r->w[i] = t[i];
    r->n = a->n + b->n;
    bn_norm(r);
}

void bn_mod(tg_bn *r, const tg_bn *a, const tg_bn *m)
{
    tg_bn x;
    bn_zero(&x);
    int bits = bn_bits(a);
    for (int i = bits - 1; i >= 0; i--) {
        /* x = 2x + bit */
        uint32_t carry = (a->w[i >> 5] >> (i & 31)) & 1u;
        for (int j = 0; j < x.n; j++) {
            uint32_t v = x.w[j];
            x.w[j] = (v << 1) | carry;
            carry = v >> 31;
        }
        if (carry && x.n < BN_MAX) { x.w[x.n] = carry; x.n++; }
        if (bn_cmp(&x, m) >= 0) bn_sub(&x, &x, m);
    }
    *r = x;
}

/* ---- Montgomery ---- */

static uint32_t mont_n0inv(uint32_t n0)
{
    uint32_t inv = n0;                    /* poprawne 3 bity dla nieparzystego n0 */
    for (int i = 0; i < 5; i++) inv *= 2u - n0 * inv;
    return (uint32_t)0 - inv;
}

/* t = a*b*R^-1 mod n; wszystkie tablice po k cyfr, wyniki < n */
static void mont_mul(uint32_t *out, const uint32_t *a, const uint32_t *b, const uint32_t *n, uint32_t n0inv, int k)
{
    uint32_t T[BN_MAX + 2];
    for (int i = 0; i < k + 2; i++) T[i] = 0;
    for (int i = 0; i < k; i++) {
        uint64_t c = 0;
        for (int j = 0; j < k; j++) {
            uint64_t s = (uint64_t)T[j] + (uint64_t)a[j] * b[i] + c;
            T[j] = (uint32_t)s;
            c = s >> 32;
        }
        uint64_t s = (uint64_t)T[k] + c;
        T[k] = (uint32_t)s;
        T[k + 1] = (uint32_t)(s >> 32);
        uint32_t m = T[0] * n0inv;
        s = (uint64_t)T[0] + (uint64_t)m * n[0];
        c = s >> 32;
        for (int j = 1; j < k; j++) {
            s = (uint64_t)T[j] + (uint64_t)m * n[j] + c;
            T[j - 1] = (uint32_t)s;
            c = s >> 32;
        }
        s = (uint64_t)T[k] + c;
        T[k - 1] = (uint32_t)s;
        c = s >> 32;
        T[k] = T[k + 1] + (uint32_t)c;
    }
    /* odejmij n, jeśli T >= n */
    int ge = T[k] != 0;
    if (!ge) {
        ge = 1;
        for (int i = k - 1; i >= 0; i--) {
            if (T[i] != n[i]) { ge = T[i] > n[i]; break; }
        }
    }
    if (ge) {
        int64_t borrow = 0;
        for (int i = 0; i < k; i++) {
            int64_t d = (int64_t)T[i] - (int64_t)n[i] - borrow;
            if (d < 0) { d += ((int64_t)1 << 32); borrow = 1; } else borrow = 0;
            T[i] = (uint32_t)d;
        }
    }
    for (int i = 0; i < k; i++) out[i] = T[i];
}

typedef struct {
    uint32_t n[BN_MAX], rr[BN_MAX];
    uint32_t n0inv;
    int k;
} mont_ctx;

static int mont_init(mont_ctx *m, const tg_bn *mod)
{
    if (mod->n == 0 || (mod->w[0] & 1u) == 0 || mod->n > 66) return 0;
    m->k = mod->n;
    for (int i = 0; i < BN_MAX; i++) { m->n[i] = i < mod->n ? mod->w[i] : 0; m->rr[i] = 0; }
    m->n0inv = mont_n0inv(mod->w[0]);
    /* R^2 mod n, gdzie R = 2^(32k) */
    tg_bn r2, red;
    bn_zero(&r2);
    int bit = 64 * m->k;
    r2.w[bit >> 5] = 1u << (bit & 31);
    r2.n = (bit >> 5) + 1;
    bn_mod(&red, &r2, mod);
    for (int i = 0; i < m->k; i++) m->rr[i] = red.w[i];
    return 1;
}

int bn_modmul(tg_bn *r, const tg_bn *a, const tg_bn *b, const tg_bn *mod)
{
    mont_ctx m;
    if (!mont_init(&m, mod)) return 0;
    tg_bn ar, br;
    bn_mod(&ar, a, mod);
    bn_mod(&br, b, mod);
    uint32_t A[BN_MAX], B[BN_MAX], t[BN_MAX], t2[BN_MAX];
    for (int i = 0; i < m.k; i++) { A[i] = i < ar.n ? ar.w[i] : 0; B[i] = i < br.n ? br.w[i] : 0; }
    mont_mul(t, A, m.rr, m.n, m.n0inv, m.k);          /* a*R */
    mont_mul(t2, t, B, m.n, m.n0inv, m.k);            /* a*b */
    bn_zero(r);
    for (int i = 0; i < m.k; i++) r->w[i] = t2[i];
    r->n = m.k;
    bn_norm(r);
    return 1;
}

int bn_modexp(tg_bn *r, const tg_bn *base, const uint8_t *exp, size_t explen, const tg_bn *mod)
{
    mont_ctx m;
    if (!mont_init(&m, mod)) return 0;
    tg_bn br;
    bn_mod(&br, base, mod);
    uint32_t B[BN_MAX], one[BN_MAX], bm[BN_MAX], acc[BN_MAX], tmp[BN_MAX];
    for (int i = 0; i < m.k; i++) { B[i] = i < br.n ? br.w[i] : 0; one[i] = 0; }
    one[0] = 1;
    mont_mul(bm, B, m.rr, m.n, m.n0inv, m.k);          /* base*R */
    mont_mul(acc, one, m.rr, m.n, m.n0inv, m.k);       /* 1*R */
    int started = 0;
    for (size_t i = 0; i < explen; i++) {
        for (int bit = 7; bit >= 0; bit--) {
            int v = (exp[i] >> bit) & 1;
            if (started) {
                mont_mul(tmp, acc, acc, m.n, m.n0inv, m.k);
                for (int j = 0; j < m.k; j++) acc[j] = tmp[j];
            }
            if (v) {
                mont_mul(tmp, acc, bm, m.n, m.n0inv, m.k);
                for (int j = 0; j < m.k; j++) acc[j] = tmp[j];
                started = 1;
            }
        }
    }
    mont_mul(tmp, acc, one, m.n, m.n0inv, m.k);        /* z powrotem z postaci Montgomery'ego */
    bn_zero(r);
    for (int i = 0; i < m.k; i++) r->w[i] = tmp[i];
    r->n = m.k;
    bn_norm(r);
    return 1;
}
