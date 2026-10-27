/*
 * Zastępcze pliki SDK (.tbd), z których budujemy aplikację na GitHubie, nie wymieniają kilku
 * podstawowych funkcji C. Linker kończył wtedy pracę błędem "Undefined symbols: _memcpy, _memset…".
 * Dlatego te funkcje mamy tutaj własne. Każda ma optnone, żeby kompilator nie zamienił
 * pętli z powrotem na wywołanie memcpy/memset (to byłaby nieskończona rekurencja).
 */
#include <stddef.h>

#define WL_PLAIN __attribute__((optnone, noinline))

WL_PLAIN void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dst;
}

WL_PLAIN void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

WL_PLAIN int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    while (n--) {
        if (*x != *y) return (int)*x - (int)*y;
        x++;
        y++;
    }
    return 0;
}

WL_PLAIN void *memchr(const void *s, int c, size_t n)
{
    const unsigned char *p = (const unsigned char *)s;
    while (n--) {
        if (*p == (unsigned char)c) return (void *)p;
        p++;
    }
    return NULL;
}

WL_PLAIN char *strchr(const char *s, int c)
{
    for (;; s++) {
        if (*s == (char)c) return (char *)s;
        if (*s == 0) return NULL;
    }
}

WL_PLAIN int strncmp(const char *a, const char *b, size_t n)
{
    while (n--) {
        unsigned char x = (unsigned char)*a++, y = (unsigned char)*b++;
        if (x != y) return (int)x - (int)y;
        if (x == 0) return 0;
    }
    return 0;
}

WL_PLAIN void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

WL_PLAIN int strcmp(const char *a, const char *b)
{
    for (;; a++, b++) {
        unsigned char x = (unsigned char)*a, y = (unsigned char)*b;
        if (x != y) return (int)x - (int)y;
        if (x == 0) return 0;
    }
}

/* clang zamienia niektóre pętle wypełniania na to wywołanie, a zastępczy SDK go nie zna */
WL_PLAIN void memset_pattern16(void *dst, const void *pattern, size_t len)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *p = (const unsigned char *)pattern;
    for (size_t i = 0; i < len; i++) d[i] = p[i & 15];
}

/* dzielenie 64-bitowe ze znakiem (Opus używa go raz w analizie tonu); bez operatorów / i %, żeby nie wołać samego siebie */
WL_PLAIN long long __divdi3(long long a, long long b)
{
    int neg = 0;
    unsigned long long ua, ub, q = 0, r = 0;
    int i;
    if (b == 0) return 0;
    if (a < 0) { ua = 0ULL - (unsigned long long)a; neg ^= 1; } else ua = (unsigned long long)a;
    if (b < 0) { ub = 0ULL - (unsigned long long)b; neg ^= 1; } else ub = (unsigned long long)b;
    for (i = 63; i >= 0; i--) {
        r = (r << 1) | ((ua >> i) & 1ULL);
        if (r >= ub) { r -= ub; q |= (1ULL << i); }
    }
    return neg ? (long long)(0ULL - q) : (long long)q;
}

/* dzielenie 32-bitowe (armv7 w iPhone 4S nie ma sprzętowego dzielenia, kompilator woła te funkcje z libcompiler_rt).
   Mamy własne, żeby aplikacja nie zależała od tego, czy SDK i iOS 6 je udostępniają. */
WL_PLAIN static unsigned int ac_udivmod(unsigned int n, unsigned int d, unsigned int *rem)
{
    unsigned int q = 0, r = 0;
    int i;
    if (d == 0 || n == 0) { *rem = 0; return 0; }
    for (i = 31 - __builtin_clz(n); i >= 0; i--) {
        unsigned int carry = r >> 31;
        r = (r << 1) | ((n >> i) & 1u);
        if (carry || r >= d) { r -= d; q |= (1u << i); }
    }
    *rem = r;
    return q;
}

WL_PLAIN unsigned int __udivsi3(unsigned int n, unsigned int d) { unsigned int r; return ac_udivmod(n, d, &r); }
WL_PLAIN unsigned int __umodsi3(unsigned int n, unsigned int d) { unsigned int r; ac_udivmod(n, d, &r); return r; }

WL_PLAIN int __divsi3(int a, int b)
{
    unsigned int r, q;
    int neg = 0;
    unsigned int ua = (unsigned int)a, ub = (unsigned int)b;
    if (a < 0) { ua = 0u - ua; neg ^= 1; }
    if (b < 0) { ub = 0u - ub; neg ^= 1; }
    q = ac_udivmod(ua, ub, &r);
    return neg ? (int)(0u - q) : (int)q;
}

WL_PLAIN int __modsi3(int a, int b)
{
    unsigned int r;
    unsigned int ua = a < 0 ? 0u - (unsigned int)a : (unsigned int)a, ub = b < 0 ? 0u - (unsigned int)b : (unsigned int)b;
    ac_udivmod(ua, ub, &r);
    return a < 0 ? (int)(0u - r) : (int)r;
}
