#ifndef TG_MT_H
#define TG_MT_H
/* MTProto 2.0: połączenie TCP (transport "intermediate"), wymiana kluczy, szyfrowana sesja, SRP (hasło 2FA). */
#include <stdint.h>
#include <stddef.h>

typedef struct tg_conn tg_conn;

typedef struct {
    void *ud;
    /* wywoływane z wątku odbioru (tg_conn_run) */
    void (*on_result)(void *ud, uint32_t token, const uint8_t *tl, size_t len);
    void (*on_error)(void *ud, uint32_t token, int code, const char *msg);
    void (*on_update)(void *ud, const uint8_t *tl, size_t len);
    void (*on_closed)(void *ud, const char *reason);
} tg_events;

tg_conn *tg_conn_new(const tg_events *ev);
void tg_conn_free(tg_conn *c);

int tg_conn_open(tg_conn *c, const char *ip, int port, int timeout_ms, char *err, int errlen);   /* 0 = ok */
int tg_conn_handshake(tg_conn *c, char *err, int errlen);                                        /* tworzy nowy klucz autoryzacji */
void tg_conn_set_auth(tg_conn *c, const uint8_t key[256], uint64_t salt, int32_t time_offset);   /* użyj zapisanego klucza */
int tg_conn_get_auth(tg_conn *c, uint8_t key[256], uint64_t *salt, int32_t *time_offset);        /* 1 gdy jest klucz */
int32_t tg_conn_time_offset(tg_conn *c);

/* wysyła zapytanie (TL funkcji); zwraca token (>0) albo 0 przy błędzie. Można z dowolnego wątku. */
uint32_t tg_conn_request(tg_conn *c, const uint8_t *tl, size_t len);
/* pętla odbioru: blokuje do zamknięcia połączenia; na końcu wywołuje on_closed */
void tg_conn_run(tg_conn *c);
void tg_conn_close(tg_conn *c);
int tg_conn_is_open(tg_conn *c);

/* testy / własny klucz RSA serwera (n 256 B, e = 65537) */
void tg_add_rsa_key(const uint8_t n[256]);

/* hasło dwuskładnikowe (SRP). Zwraca 0 = ok.
   rnd256 = 256 losowych bajtów (parametr, żeby dało się testować). */
int tg_srp_check(const uint8_t *salt1, size_t salt1_len, const uint8_t *salt2, size_t salt2_len,
                 int32_t g, const uint8_t p[256], const uint8_t srp_b[256], size_t srp_b_len,
                 const uint8_t *password, size_t password_len, const uint8_t rnd256[256],
                 uint8_t out_a[256], uint8_t out_m1[32]);

#endif
