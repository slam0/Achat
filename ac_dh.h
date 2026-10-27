#ifndef AC_DH_H
#define AC_DH_H
/* Wymiana kluczy Diffiego-Hellmana dla rozmów (liczby 2048-bitowe, big-endian, zawsze 256 bajtów). */
#include <stdint.h>
#include <stddef.h>

/* 0 = wygląda na bezpieczną liczbę pierwszą 2048-bitową (test Fermata dla p i (p-1)/2; trwa ok. sekundy) */
int acdh_check_prime(const uint8_t p[256]);
/* out = base^exp mod p; base to liczba big-endian o długości baselen (np. jeden bajt g); 0 = ok */
int acdh_pow(const uint8_t p[256], const uint8_t *base, size_t baselen, const uint8_t exp[256], uint8_t out[256]);
/* sprawdza wartość publiczną drugiej strony: 2^1984 < x < p - 2^1984; 0 = ok */
int acdh_check_public(const uint8_t p[256], const uint8_t x[256]);

#endif
