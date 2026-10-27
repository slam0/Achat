#ifndef AC_TGC_H
#define AC_TGC_H
/*
 * Silnik rozmów głosowych zgodny z biblioteką tgcalls (wersja "2.7.7") — taką, jakiej używają obecne
 * aplikacje Telegrama (Android, iOS, Desktop) po stronie rozmówcy.
 *
 * Budowa protokołu (zob. tgalls: Manager, NetworkManager, EncryptedConnection, Message, MediaManager):
 *  - transport: ICE (pakiety STUN z hasłem z sygnalizacji) przez serwery pośredniczące Telegrama ("reflector"),
 *  - szyfrowanie: własne AES-256-CTR z kluczem rozmowy (EncryptedConnection), potwierdzenia i ponowne wysyłanie,
 *  - sygnalizacja (kandydaci ICE, hasła, stan wyciszenia) idzie przez MTProto: phone.sendSignalingData,
 *  - dźwięk: Opus w pakietach RTP (PT 111, SSRC 1/2) zapakowanych jako wiadomość AudioData.
 * Silnik nie dotyka karty dźwiękowej: system podaje próbki z mikrofonu (acg_push_capture)
 * i pobiera próbki do odtworzenia (acg_pull_playout).
 */
#include <stdint.h>
#include <stddef.h>

#define ACG_SAMPLE_RATE 16000

/* te same wartości liczbowe co w starym silniku, żeby interfejs rozmowy mógł ich używać bez zmian */
enum { ACG_STATE_WAIT_INIT = 1, ACG_STATE_CONNECTING = 2, ACG_STATE_ESTABLISHED = 3, ACG_STATE_FAILED = 4, ACG_STATE_RECONNECTING = 5 };
enum { ACG_ERR_NONE = 0, ACG_ERR_TIMEOUT = 1, ACG_ERR_INCOMPATIBLE = 2, ACG_ERR_UNKNOWN = 3, ACG_ERR_SOCKET = 4, ACG_ERR_CODEC = 5 };

typedef struct acg acg;
typedef void (*acg_state_cb)(void *ud, int state, int error);                        /* z wątku silnika */
typedef void (*acg_signal_cb)(void *ud, const uint8_t *data, int len);               /* z wątku silnika: wyślij phone.sendSignalingData */
typedef void (*acg_log_cb)(const char *line);

acg *acg_new(const uint8_t key[256], int is_outgoing, acg_state_cb scb, acg_signal_cb sigcb, void *ud);
/* serwer pośredniczący: id (1..n, z posortowanej listy id połączeń), adres IPv4, port, peer_tag (16 bajtów) */
int acg_add_reflector(acg *g, int id, const char *ip, int port, const uint8_t peer_tag[16]);
int acg_start(acg *g, char *err, int errlen);
void acg_stop(acg *g);
void acg_free(acg *g);
void acg_signaling_in(acg *g, const uint8_t *data, int len);                         /* z dowolnego wątku */
void acg_set_mute(acg *g, int mute);
int acg_peer_muted(acg *g);
int acg_state(acg *g);
void acg_push_capture(acg *g, const int16_t *pcm, int n);                            /* mikrofon, 16 kHz mono */
void acg_pull_playout(acg *g, int16_t *pcm, int n);                                  /* głośnik; zawsze wypełnia n próbek */
void acg_set_log(acg_log_cb cb);
/* jednowierszowe podsumowanie diagnostyczne */
void acg_describe(acg *g, char *out, int outlen);
void acg_short(acg *g, char *out, int outlen);                                      /* krótka linia na ekran rozmowy (zeruje szczyty) */

#endif
