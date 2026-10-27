#ifndef TG_BN_H
#define TG_BN_H
/* Liczby wielkie (do 4400 bitów) potrzebne do RSA, Diffiego-Hellmana i SRP.
   Bez dzielenia: redukcja metodą Montgomery'ego, reszta przez odejmowanie. */
#include <stdint.h>
#include <stddef.h>

#define BN_MAX 140

typedef struct {
    uint32_t w[BN_MAX];     /* cyfry 32-bitowe, najmłodsza pierwsza */
    int n;                  /* liczba użytych cyfr (bez zer wiodących) */
} tg_bn;

void bn_zero(tg_bn *a);
void bn_set_u32(tg_bn *a, uint32_t v);
void bn_from_be(tg_bn *a, const uint8_t *b, size_t len);
int bn_to_be(const tg_bn *a, uint8_t *out, size_t len);     /* uzupełnia zerami z przodu; 0 gdy się nie mieści */
int bn_bits(const tg_bn *a);
int bn_cmp(const tg_bn *a, const tg_bn *b);
void bn_add(tg_bn *r, const tg_bn *a, const tg_bn *b);
void bn_sub(tg_bn *r, const tg_bn *a, const tg_bn *b);      /* wymaga a >= b */
void bn_mul(tg_bn *r, const tg_bn *a, const tg_bn *b);      /* r nie może wskazywać na a ani b */
void bn_mod(tg_bn *r, const tg_bn *a, const tg_bn *m);      /* r = a mod m (powolne, bitowe) */
int bn_modexp(tg_bn *r, const tg_bn *base, const uint8_t *exp, size_t explen, const tg_bn *mod);  /* mod nieparzysty */
int bn_modmul(tg_bn *r, const tg_bn *a, const tg_bn *b, const tg_bn *mod);                         /* mod nieparzysty */

#endif
