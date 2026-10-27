#ifndef AC_VOIP_H
#define AC_VOIP_H
/*
 * Silnik rozmów głosowych Telegrama (1:1, tylko dźwięk) w czystym C.
 * Protokół jak w libtgvoip (wersja protokołu 9): pakiety UDP przez serwery przekaźnikowe Telegrama,
 * szyfrowanie kluczem z wymiany DH (MTProto 2.0 w skróconym formacie), dźwięk w Opus (16 kHz, ramki 60 ms).
 * Silnik sam nie dotyka karty dźwiękowej: system podaje mu próbki z mikrofonu (acv_push_capture)
 * i pobiera próbki do odtworzenia (acv_pull_playout).
 */
#include <stdint.h>
#include <stddef.h>

#define ACV_SAMPLE_RATE 16000

enum { ACV_STATE_WAIT_INIT = 1, ACV_STATE_WAIT_INIT_ACK = 2, ACV_STATE_ESTABLISHED = 3, ACV_STATE_FAILED = 4, ACV_STATE_RECONNECTING = 5 };
enum { ACV_ERR_NONE = 0, ACV_ERR_TIMEOUT = 1, ACV_ERR_INCOMPATIBLE = 2, ACV_ERR_UNKNOWN = 3, ACV_ERR_SOCKET = 4, ACV_ERR_CODEC = 5 };

typedef struct acv acv;
typedef void (*acv_state_cb)(void *ud, int state, int error);      /* wywoływane z wątku silnika */
typedef void (*acv_log_cb)(const char *line);

acv *acv_new(const uint8_t key[256], int is_outgoing, acv_state_cb cb, void *ud);
int acv_add_relay(acv *v, const char *ip, int port, const uint8_t tag[16]);        /* 0 = ok */
int acv_start(acv *v, char *err, int errlen);                                      /* 0 = ok */
void acv_stop(acv *v);                                                             /* zatrzymuje wątek i zamyka gniazdo */
void acv_free(acv *v);
void acv_set_mute(acv *v, int mute);
int acv_peer_muted(acv *v);
int acv_state(acv *v);
void acv_push_capture(acv *v, const int16_t *pcm, int n);                          /* mikrofon, 16 kHz mono */
void acv_pull_playout(acv *v, int16_t *pcm, int n);                                /* głośnik; zawsze wypełnia n próbek */
void acv_set_log(acv_log_cb cb);
/* diagnostyka */
void acv_stats(acv *v, uint32_t *sent, uint32_t *recvd, uint32_t *lost);

#endif
