#include "ac_dh.h"
#include "tg_bn.h"
#include <string.h>

int acdh_pow(const uint8_t p[256], const uint8_t *base, size_t baselen, const uint8_t exp[256], uint8_t out[256])
{
    tg_bn m, b, r;
    if (baselen == 0 || baselen > 256 || !(p[255] & 1)) return -1;
    bn_from_be(&m, p, 256);
    bn_from_be(&b, base, baselen);
    if (bn_cmp(&b, &m) >= 0) return -1;
    if (!bn_modexp(&r, &b, exp, 256, &m)) return -1;
    if (!bn_to_be(&r, out, 256)) return -1;
    return 0;
}

int acdh_check_public(const uint8_t p[256], const uint8_t x[256])
{
    tg_bn P, X, lo, hi;
    uint8_t lob[256];
    bn_from_be(&P, p, 256);
    bn_from_be(&X, x, 256);
    memset(lob, 0, sizeof(lob));
    lob[7] = 1;                                     /* 2^1984 */
    bn_from_be(&lo, lob, 256);
    if (bn_cmp(&P, &lo) <= 0) return -1;
    bn_sub(&hi, &P, &lo);
    if (bn_cmp(&X, &lo) <= 0) return -1;
    if (bn_cmp(&X, &hi) >= 0) return -1;
    return 0;
}

int acdh_check_prime(const uint8_t p[256])
{
    uint8_t two = 2, pm1[256], q[256], qm1[256], out[256], one[256];
    int i;
    tg_bn m, b, r;
    if (!(p[0] & 0x80) || !(p[255] & 1) || (p[255] & 3) != 3) return -1;
    memset(one, 0, sizeof(one));
    one[255] = 1;
    /* 2^(p-1) mod p == 1 */
    memcpy(pm1, p, 256);
    pm1[255] &= 0xFE;
    if (acdh_pow(p, &two, 1, pm1, out) != 0 || memcmp(out, one, 256) != 0) return -1;
    /* q = (p-1)/2 */
    for (i = 255; i >= 0; i--) q[i] = (uint8_t)((pm1[i] >> 1) | (i > 0 ? (pm1[i - 1] << 7) : 0));
    /* 2^(q-1) mod q == 1  (q jest nieparzyste, bo p = 3 mod 4) */
    memcpy(qm1, q, 256);
    qm1[255] &= 0xFE;
    bn_from_be(&m, q, 256);
    bn_from_be(&b, &two, 1);
    if (!bn_modexp(&r, &b, qm1, 256, &m)) return -1;
    if (!bn_to_be(&r, out, 256) || memcmp(out, one, 256) != 0) return -1;
    return 0;
}
