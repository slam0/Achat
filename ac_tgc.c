#include "ac_tgc.h"
#include "tg_crypto.h"
#include "opus.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* ======================================================================
 * Stałe (tgcalls 2.7.7)
 * ====================================================================== */
#define MAX_PORTS 16
#define MAX_PAIRS 64
#define MAX_PKT 1700
#define SIGQ 48

#define EC_LIMIT_TRANSPORT 1452            /* kMaxFullPacketSize - 48 */
#define EC_LIMIT_SIGNALING 16384
#define EC_MAXUNACKED 24
#define EC_MSGCAP 700

#define MSG_CANDIDATES 1
#define MSG_VIDEO_FORMATS 2
#define MSG_REQUEST_VIDEO 3
#define MSG_MEDIA_STATE 4
#define MSG_AUDIO 5
#define MSG_VIDEO 6
#define MSG_UNSTRUCTURED 7
#define MSG_VIDEO_PARAMS 8
#define MSG_BATTERY 9
#define MSG_NETWORK 10
#define MSG_EMPTY 0xFE
#define MSG_ACK 0xFF

#define SEQ_SINGLE 0x80000000u
#define SEQ_ACKREQ 0x40000000u
#define SEQ_COUNTER_MASK 0x3FFFFFFFu

#define RTP_PT_OPUS 111
#define FRAME_MS 60
#define FRAME_SAMPLES (ACG_SAMPLE_RATE / 1000 * FRAME_MS)       /* 960 */
#define MAX_DEC_SAMPLES (ACG_SAMPLE_RATE / 1000 * 120)          /* 1920 */
#define CAP_RING 8192
#define JB_SIZE 24
#define JB_DATA 1100
#define FIFO_SIZE 4096

/* ======================================================================
 * Pomocnicze
 * ====================================================================== */
static acg_log_cb g_log;
void acg_set_log(acg_log_cb cb) { g_log = cb; }

static void logf_(const char *fmt, ...)
{
    char b[400];
    va_list ap;
    if (!g_log) return;
    va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    g_log(b);
}

static void wbe16(uint8_t *p, uint32_t x) { p[0] = (uint8_t)(x >> 8); p[1] = (uint8_t)x; }
static void wbe32(uint8_t *p, uint32_t x) { p[0] = (uint8_t)(x >> 24); p[1] = (uint8_t)(x >> 16); p[2] = (uint8_t)(x >> 8); p[3] = (uint8_t)x; }
static void wle32(uint8_t *p, uint32_t x) { p[0] = (uint8_t)x; p[1] = (uint8_t)(x >> 8); p[2] = (uint8_t)(x >> 16); p[3] = (uint8_t)(x >> 24); }
static uint32_t rbe16(const uint8_t *p) { return ((uint32_t)p[0] << 8) | p[1]; }
static uint32_t rbe32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint32_t rle32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

/* ======================================================================
 * Kryptografia: HMAC-SHA1, AES-256-CTR, KDF z tgcalls (CryptoHelper.cpp)
 * ====================================================================== */
static void hmac_sha1(const uint8_t *key, int klen, const uint8_t *d, int n, uint8_t out[20])
{
    uint8_t k[64], ipad[64], opad[64], inner[20];
    tg_sha1_ctx c;
    int i;
    memset(k, 0, sizeof(k));
    if (klen > 64) tg_sha1(key, (size_t)klen, k);
    else memcpy(k, key, (size_t)klen);
    for (i = 0; i < 64; i++) { ipad[i] = (uint8_t)(k[i] ^ 0x36); opad[i] = (uint8_t)(k[i] ^ 0x5c); }
    tg_sha1_init(&c);
    tg_sha1_update(&c, ipad, 64);
    tg_sha1_update(&c, d, (size_t)n);
    tg_sha1_final(&c, inner);
    tg_sha1_init(&c);
    tg_sha1_update(&c, opad, 64);
    tg_sha1_update(&c, inner, 20);
    tg_sha1_final(&c, out);
}

static void aes_ctr(const uint8_t key[32], const uint8_t iv[16], const uint8_t *in, uint8_t *out, int n)
{
    tg_aes a;
    uint8_t ctr[16], ks[16];
    int i, j;
    tg_aes_set_key(&a, key);
    memcpy(ctr, iv, 16);
    for (i = 0; i < n; i += 16) {
        int m = n - i < 16 ? n - i : 16;
        tg_aes_encrypt_block(&a, ctr, ks);
        for (j = 0; j < m; j++) out[i + j] = (uint8_t)(in[i + j] ^ ks[j]);
        for (j = 15; j >= 0; j--) { if (++ctr[j] != 0) break; }
    }
}

static void tgc_kdf(const uint8_t *key, const uint8_t mk[16], int x, uint8_t aes_key[32], uint8_t iv[16])
{
    uint8_t buf[52], sa[32], sb[32];
    memcpy(buf, mk, 16);
    memcpy(buf + 16, key + x, 36);
    tg_sha256(buf, 52, sa);
    memcpy(buf, key + 40 + x, 36);
    memcpy(buf + 36, mk, 16);
    tg_sha256(buf, 52, sb);
    memcpy(aes_key, sa, 8);
    memcpy(aes_key + 8, sb + 8, 16);
    memcpy(aes_key + 24, sa + 24, 8);
    memcpy(iv, sb, 4);
    memcpy(iv + 4, sa + 8, 8);
    memcpy(iv + 12, sb + 24, 4);
}

/* ======================================================================
 * EncryptedConnection (EncryptedConnection.cpp)
 * ====================================================================== */
typedef struct { uint8_t d[EC_MSGCAP]; int n; uint32_t last_sent; } ec_msg;

typedef struct {
    int sig;                       /* 0 = Transport, 1 = Signaling */
    const uint8_t *key;
    int outgoing;
    uint32_t counter;
    uint32_t inc[64]; int ninc;            /* największe odebrane liczniki (posortowane) */
    uint32_t acks[64]; int nacks;          /* seq do potwierdzenia */
    uint32_t sent_acks[64]; int nsent;     /* licznik wiadomości z ACK już odebranych (posortowane) */
    ec_msg un[EC_MAXUNACKED]; int nun;     /* nasze nie potwierdzone wiadomości */
    int min_resend, max_resend, max_ack;
    int resend_active, ack_active, ack_now;
    uint32_t resend_due, ack_due;
    int limit;
    /* statystyki */
    uint32_t n_bad_hash, n_bad_fmt, n_dup, n_ok;
} ec_t;

static void ec_init(ec_t *e, int sig, const uint8_t *key, int outgoing)
{
    memset(e, 0, sizeof(*e));
    e->sig = sig;
    e->key = key;
    e->outgoing = outgoing;
    e->min_resend = sig ? 3000 : 300;
    e->max_resend = sig ? 5000 : 1000;
    e->max_ack = sig ? 5000 : 1000;
    e->limit = sig ? EC_LIMIT_SIGNALING : EC_LIMIT_TRANSPORT;
}

static int ec_have_add(const ec_t *e) { return e->nun > 0 || e->nacks > 0; }
static int ec_space(const ec_t *e, int cur, int amount) { return amount < e->limit && 16 + cur + amount <= e->limit; }

static void ec_append_acks(ec_t *e, uint8_t *buf, int *n)
{
    int i = 0;
    while (i < e->nacks && ec_space(e, *n, 5)) {
        wbe32(buf + *n, e->acks[i]);
        buf[*n + 4] = MSG_ACK;
        *n += 5;
        i++;
    }
    if (i > 0) { memmove(e->acks, e->acks + i, (size_t)(e->nacks - i) * 4); e->nacks -= i; }
}

static void ec_append_additional(ec_t *e, uint8_t *buf, int *n, uint32_t now)
{
    int i;
    ec_append_acks(e, buf, n);
    if (e->nun == 0) return;
    for (i = 0; i < e->nun; i++) {
        ec_msg *m = &e->un[i];
        uint32_t when = m->last_sent ? m->last_sent + (uint32_t)e->min_resend : 0;
        if (when > now) break;
        if (!ec_space(e, *n, m->n)) break;
        memcpy(buf + *n, m->d, (size_t)m->n);
        *n += m->n;
        m->last_sent = now ? now : 1;
    }
    if (!e->resend_active) { e->resend_active = 1; e->resend_due = now + (uint32_t)e->max_resend; }
}

static int ec_encrypt(ec_t *e, const uint8_t *plain, int n, uint8_t *out)
{
    int x = (e->outgoing ? 0 : 8) + (e->sig ? 128 : 0);
    uint8_t mk32[32], ak[32], iv[16];
    tg_sha256_ctx c;
    tg_sha256_init(&c);
    tg_sha256_update(&c, e->key + 88 + x, 32);
    tg_sha256_update(&c, plain, (size_t)n);
    tg_sha256_final(&c, mk32);
    memcpy(out, mk32 + 8, 16);
    tgc_kdf(e->key, out, x, ak, iv);
    aes_ctr(ak, iv, plain, out + 16, n);
    return 16 + n;
}

static uint32_t ec_next_seq(ec_t *e, int ackreq, int single)
{
    return (++e->counter) | (single ? SEQ_SINGLE : 0) | (ackreq ? SEQ_ACKREQ : 0);
}

/* pakiet usługowy: pusta wiadomość + potwierdzenia + ponowne wysłania */
static int ec_service(ec_t *e, int cause, uint8_t *out, uint32_t now)
{
    uint8_t buf[MAX_PKT + EC_LIMIT_SIGNALING];
    int n = 0;
    uint32_t seq;
    if (cause == 1) e->ack_active = 0;
    else if (cause == 2) e->resend_active = 0;
    if (!ec_have_add(e)) return 0;
    seq = ec_next_seq(e, 0, 0);
    wbe32(buf, seq);
    buf[4] = MSG_EMPTY;
    n = 5;
    ec_append_additional(e, buf, &n, now);
    return ec_encrypt(e, buf, n, out);
}

/* wiadomość bez ACK (dźwięk) */
static int ec_send_data(ec_t *e, int type, const uint8_t *data, int dlen, uint8_t *out, uint32_t now)
{
    uint8_t buf[MAX_PKT];
    int single = !ec_have_add(e), n;
    uint32_t seq;
    if (dlen + 16 > MAX_PKT - 16 || 16 + 7 + dlen > e->limit) return 0;
    seq = ec_next_seq(e, 0, single);
    wbe32(buf, seq);
    buf[4] = (uint8_t)type;
    n = 5;
    if (!single) { wbe16(buf + n, (uint32_t)dlen); n += 2; }
    memcpy(buf + n, data, (size_t)dlen);
    n += dlen;
    ec_append_additional(e, buf, &n, now);
    return ec_encrypt(e, buf, n, out);
}

/* wiadomość z ACK (kandydaci, stan wyciszenia); ciało bez prefiksu długości */
static int ec_send_reliable(ec_t *e, int type, const uint8_t *body, int blen, uint8_t *out, uint32_t now)
{
    uint8_t buf[MAX_PKT + EC_LIMIT_SIGNALING];
    uint32_t seq;
    int n, send_enq;
    ec_msg *m;
    if (blen + 5 > EC_MSGCAP || e->nun >= EC_MAXUNACKED) return 0;
    seq = ec_next_seq(e, 1, 0);
    wbe32(buf, seq);
    buf[4] = (uint8_t)type;
    memcpy(buf + 5, body, (size_t)blen);
    n = 5 + blen;
    send_enq = e->nun > 0;
    m = &e->un[e->nun];
    memcpy(m->d, buf, (size_t)n);
    m->n = n;
    m->last_sent = now ? now : 1;
    if (!send_enq) ec_append_additional(e, buf, &n, now);   /* tylko potwierdzenia (kolejka była pusta) */
    e->nun++;
    if (!e->resend_active) { e->resend_active = 1; e->resend_due = now + (uint32_t)e->max_resend; }
    if (!send_enq) return ec_encrypt(e, buf, n, out);
    {
        int i;
        for (i = 0; i < e->nun; i++) e->un[i].last_sent = 0;
    }
    return ec_service(e, 0, out, now);
}

static int ec_register_incoming(ec_t *e, uint32_t c)
{
    int pos = 0, i, et;
    uint32_t largest = e->ninc ? e->inc[e->ninc - 1] : 0;
    while (pos < e->ninc && e->inc[pos] < c) pos++;
    if (pos < e->ninc && e->inc[pos] == c) return 0;
    if (c + 64u <= largest) return 0;
    et = 0;
    while (et < e->ninc && !(e->inc[et] + 64u > c)) et++;
    pos -= et;
    if (et > 0) { memmove(e->inc, e->inc + et, (size_t)(e->ninc - et) * 4); e->ninc -= et; }
    if (e->ninc >= 64) { memmove(e->inc, e->inc + 1, (size_t)(e->ninc - 1) * 4); e->ninc--; if (pos > 0) pos--; }
    if (pos < 0) pos = 0;
    for (i = e->ninc; i > pos; i--) e->inc[i] = e->inc[i - 1];
    e->inc[pos] = c;
    e->ninc++;
    return 1;
}

static int ec_register_sent_ack(ec_t *e, uint32_t counter, int first)
{
    int pos = 0, already, i;
    while (pos < e->nsent && e->sent_acks[pos] < counter) pos++;
    already = pos < e->nsent && e->sent_acks[pos] == counter;
    if (first) {
        if (pos > 0) { memmove(e->sent_acks, e->sent_acks + pos, (size_t)(e->nsent - pos) * 4); e->nsent -= pos; }
        if (!already) {
            if (e->nsent >= 64) e->nsent--;
            for (i = e->nsent; i > 0; i--) e->sent_acks[i] = e->sent_acks[i - 1];
            e->sent_acks[0] = counter;
            e->nsent++;
        }
    } else if (!already) {
        if (e->nsent >= 64) { memmove(e->sent_acks, e->sent_acks + 1, (size_t)(e->nsent - 1) * 4); e->nsent--; if (pos > 0) pos--; }
        for (i = e->nsent; i > pos; i--) e->sent_acks[i] = e->sent_acks[i - 1];
        e->sent_acks[pos] = counter;
        e->nsent++;
    }
    return !already;
}

static void ec_ack_postponed(ec_t *e, uint32_t seq)
{
    int i;
    for (i = 0; i < e->nacks; i++) if (e->acks[i] == seq) return;
    if (e->nacks < 64) e->acks[e->nacks++] = seq;
}

static void ec_ack_mine(ec_t *e, uint32_t seq)
{
    int i;
    for (i = 0; i < e->nun; i++) {
        if (rbe32(e->un[i].d) == seq) {
            memmove(&e->un[i], &e->un[i + 1], (size_t)(e->nun - i - 1) * sizeof(ec_msg));
            e->nun--;
            return;
        }
    }
}

/* długość ciała wiadomości o danym typie; -1 = błąd. *skip = bajty prefiksu długości */
static int msg_body_len(int type, const uint8_t *p, int avail, int single, int *skip)
{
    *skip = 0;
    switch (type) {
    case MSG_REQUEST_VIDEO: return 0;
    case MSG_MEDIA_STATE: case MSG_BATTERY: return avail >= 1 ? 1 : -1;
    case MSG_NETWORK: return avail >= 1 ? (avail >= 2 ? 2 : 1) : -1;
    case MSG_VIDEO_PARAMS: return avail >= 4 ? 4 : -1;
    case MSG_AUDIO: case MSG_VIDEO: case MSG_UNSTRUCTURED:
        if (single) return avail;
        if (avail < 2) return -1;
        { int l = (int)rbe16(p); if (avail < 2 + l) return -1; *skip = 2; return l; }
    case MSG_CANDIDATES: {
        int o = 0, i, cnt, k;
        if (avail < 1) return -1;
        cnt = p[o++];
        for (i = 0; i < cnt + 2; i++) {          /* kandydaci, ufrag, pwd: napisy z 32-bitową długością */
            uint32_t l;
            if (avail - o < 4) return -1;
            l = rbe32(p + o);
            o += 4;
            if (l >= 65536 || (int)l > avail - o) return -1;
            o += (int)l;
        }
        (void)k;
        return o;
    }
    case MSG_VIDEO_FORMATS: {
        int o = 0, cnt, i, j;
        if (avail < 1) return -1;
        cnt = p[o++];
        for (i = 0; i < cnt; i++) {
            uint32_t l;
            int pc;
            if (avail - o < 4) return -1;
            l = rbe32(p + o); o += 4;
            if (l >= 65536 || (int)l > avail - o) return -1;
            o += (int)l;
            if (avail - o < 1) return -1;
            pc = p[o++];
            for (j = 0; j < pc * 2; j++) {
                if (avail - o < 4) return -1;
                l = rbe32(p + o); o += 4;
                if (l >= 65536 || (int)l > avail - o) return -1;
                o += (int)l;
            }
        }
        if (avail - o < 1) return -1;
        o++;
        return o;
    }
    default: return -1;
    }
}

typedef void (*ec_msg_cb)(void *ud, int sig, int type, const uint8_t *body, int blen);

/* odbiór pakietu; zwraca 1, gdy pakiet był poprawny */
static int ec_receive(ec_t *e, const uint8_t *data, int size, uint32_t now, ec_msg_cb cb, void *ud)
{
    uint8_t dec[MAX_PKT + EC_LIMIT_SIGNALING], ak[32], iv[16], mk32[32];
    int x = (e->outgoing ? 8 : 0) + (e->sig ? 128 : 0);
    int dsize, o, additional = 0, first_ack = 1, new_ack = 0, single;
    uint32_t pseq, pcounter, cseq, ccounter;
    tg_sha256_ctx c;
    if (size < 21 || size > (e->sig ? EC_LIMIT_SIGNALING + 64 : MAX_PKT)) { e->n_bad_fmt++; return 0; }
    dsize = size - 16;
    if (dsize > (int)sizeof(dec)) { e->n_bad_fmt++; return 0; }
    tgc_kdf(e->key, data, x, ak, iv);
    aes_ctr(ak, iv, data + 16, dec, dsize);
    tg_sha256_init(&c);
    tg_sha256_update(&c, e->key + 88 + x, 32);
    tg_sha256_update(&c, dec, (size_t)dsize);
    tg_sha256_final(&c, mk32);
    if (memcmp(mk32 + 8, data, 16) != 0) { e->n_bad_hash++; return 0; }
    pseq = rbe32(dec);
    pcounter = pseq & SEQ_COUNTER_MASK;
    if (!ec_register_incoming(e, pcounter)) { e->n_dup++; return 0; }
    e->n_ok++;
    cseq = pseq;
    ccounter = pcounter;
    o = 4;
    for (;;) {
        int type = dec[o];
        single = (cseq & SEQ_SINGLE) != 0;
        if (single && additional) { e->n_bad_fmt++; return 0; }
        if (type == MSG_EMPTY) {
            if (additional) { e->n_bad_fmt++; return 0; }
            o++;
        } else if (type == MSG_ACK) {
            if (!additional) { e->n_bad_fmt++; return 0; }
            ec_ack_mine(e, cseq);
            o++;
        } else {
            int skip, bl, ackreq = (cseq & SEQ_ACKREQ) != 0, skipmsg;
            bl = msg_body_len(type, dec + o + 1, dsize - o - 1, single, &skip);
            if (bl < 0) { e->n_bad_fmt++; return 0; }
            if (ackreq) skipmsg = !ec_register_sent_ack(e, ccounter, first_ack);
            else skipmsg = additional && (ccounter > pcounter || !ec_register_incoming(e, ccounter));
            if (ackreq) {
                first_ack = 0;
                if (!skipmsg) new_ack = 1;
                ec_ack_postponed(e, cseq);
            }
            if (!skipmsg && cb) cb(ud, e->sig, type, dec + o + 1 + skip, bl);
            o += 1 + skip + bl;
        }
        if (o >= dsize) break;
        if (single) { e->n_bad_fmt++; return 0; }
        if (dsize - o < 5) { e->n_bad_fmt++; return 0; }
        cseq = rbe32(dec + o);
        ccounter = cseq & SEQ_COUNTER_MASK;
        o += 4;
        additional = 1;
    }
    if (e->nacks > 0) {
        if (new_ack) e->ack_now = 1;
        else if (!e->ack_active) { e->ack_active = 1; e->ack_due = now + (uint32_t)e->max_ack; }
    }
    return 1;
}

/* czy trzeba wysłać pakiet usługowy (potwierdzenia / ponowne wysłanie) */
static int ec_tick(ec_t *e, uint32_t now, uint8_t *out)
{
    int cause = -1;
    if (e->ack_now) { e->ack_now = 0; cause = 0; }
    else if (e->ack_active && (int32_t)(now - e->ack_due) >= 0) cause = 1;
    else if (e->resend_active && (int32_t)(now - e->resend_due) >= 0) cause = 2;
    if (cause < 0) return 0;
    return ec_service(e, cause, out, now);
}

/* ======================================================================
 * STUN (RFC 5389 w zakresie, którego używa libwebrtc/ICE)
 * ====================================================================== */
#define STUN_COOKIE 0x2112A442u
#define ST_BINDING_REQ 0x0001
#define ST_BINDING_OK 0x0101
#define ST_BINDING_ERR 0x0111
#define SA_USERNAME 0x0006
#define SA_INTEGRITY 0x0008
#define SA_ERROR_CODE 0x0009
#define SA_XOR_MAPPED 0x0020
#define SA_PRIORITY 0x0024
#define SA_USE_CAND 0x0025
#define SA_FINGERPRINT 0x8028
#define SA_ICE_CONTROLLED 0x8029
#define SA_ICE_CONTROLLING 0x802A

typedef struct { uint8_t b[400]; int n; } stunbuf;

static void st_begin(stunbuf *s, int type, const uint8_t txid[12])
{
    wbe16(s->b, (uint32_t)type);
    wbe16(s->b + 2, 0);
    wbe32(s->b + 4, STUN_COOKIE);
    memcpy(s->b + 8, txid, 12);
    s->n = 20;
}

static void st_attr(stunbuf *s, int type, const void *v, int l)
{
    wbe16(s->b + s->n, (uint32_t)type);
    wbe16(s->b + s->n + 2, (uint32_t)l);
    if (l > 0) memcpy(s->b + s->n + 4, v, (size_t)l);
    s->n += 4 + l;
    while (s->n % 4) s->b[s->n++] = 0;
}

static void st_finish(stunbuf *s, const char *pwd)
{
    if (pwd) {
        uint8_t mac[20];
        wbe16(s->b + 2, (uint32_t)(s->n - 20 + 24));
        hmac_sha1((const uint8_t *)pwd, (int)strlen(pwd), s->b, s->n, mac);
        st_attr(s, SA_INTEGRITY, mac, 20);
    }
    {
        uint8_t fp[4];
        wbe16(s->b + 2, (uint32_t)(s->n - 20 + 8));
        wbe32(fp, tg_crc32(s->b, (size_t)s->n) ^ 0x5354554eu);
        st_attr(s, SA_FINGERPRINT, fp, 4);
    }
    wbe16(s->b + 2, (uint32_t)(s->n - 20));
}

typedef struct {
    int type;
    uint8_t txid[12];
    const uint8_t *user; int userlen;
    int mi_off;                       /* przesunięcie atrybutu MESSAGE-INTEGRITY (-1 = brak) */
    int use_cand, controlling, controlled;
    uint64_t tiebreak;
    uint32_t prio;
    int errcode;
} st_info;

static int is_stun(const uint8_t *m, int n)
{
    if (n < 20 || (m[0] & 0xC0) != 0) return 0;
    if (rbe32(m + 4) != STUN_COOKIE) return 0;
    if ((int)rbe16(m + 2) != n - 20 || (n - 20) % 4 != 0) return 0;
    return 1;
}

static int st_parse(const uint8_t *m, int n, st_info *o)
{
    int p = 20;
    memset(o, 0, sizeof(*o));
    o->mi_off = -1;
    if (!is_stun(m, n)) return -1;
    o->type = (int)rbe16(m);
    memcpy(o->txid, m + 8, 12);
    while (p + 4 <= n) {
        int t = (int)rbe16(m + p), l = (int)rbe16(m + p + 2);
        const uint8_t *v = m + p + 4;
        if (p + 4 + l > n) return -1;
        switch (t) {
        case SA_USERNAME: o->user = v; o->userlen = l; break;
        case SA_INTEGRITY: if (l == 20) o->mi_off = p; break;
        case SA_USE_CAND: o->use_cand = 1; break;
        case SA_ICE_CONTROLLING: if (l == 8) { o->controlling = 1; o->tiebreak = ((uint64_t)rbe32(v) << 32) | rbe32(v + 4); } break;
        case SA_ICE_CONTROLLED: if (l == 8) { o->controlled = 1; o->tiebreak = ((uint64_t)rbe32(v) << 32) | rbe32(v + 4); } break;
        case SA_PRIORITY: if (l == 4) o->prio = rbe32(v); break;
        case SA_ERROR_CODE: if (l >= 4) o->errcode = (v[2] & 7) * 100 + v[3]; break;
        default: break;
        }
        p += 4 + ((l + 3) & ~3);
    }
    return 0;
}

static int st_check_integrity(const uint8_t *m, int n, const st_info *info, const char *pwd)
{
    uint8_t tmp[MAX_PKT], mac[20];
    if (info->mi_off < 0 || info->mi_off + 24 > n || info->mi_off > (int)sizeof(tmp)) return 0;
    memcpy(tmp, m, (size_t)info->mi_off);
    wbe16(tmp + 2, (uint32_t)(info->mi_off + 24 - 20));
    hmac_sha1((const uint8_t *)pwd, (int)strlen(pwd), tmp, info->mi_off, mac);
    return memcmp(mac, m + info->mi_off + 4, 20) == 0;
}

/* ======================================================================
 * Silnik
 * ====================================================================== */
typedef struct {
    int id;
    struct sockaddr_in addr;
    int sock;
    uint8_t tag12[12];
    uint32_t my_tag;
    int ready;
    uint32_t last_hello, hellos;
    uint32_t rx_pkts;
    int cand_sent;
} port_t;

typedef struct {
    int used, port;
    uint32_t rtag;
    uint8_t tx[4][12]; int ntx;
    int sent, got_resp, got_req, nominated, trigger;
    uint32_t last_sent_ms, last_rx_ms;
} pair_t;

typedef struct { int used; int32_t pts; int len; uint32_t arr; uint8_t data[JB_DATA]; } jb_t;

struct acg {
    uint8_t key[256];
    int is_outgoing;
    acg_state_cb scb;
    acg_signal_cb sigcb;
    void *ud;

    ec_t ec_t_, ec_s_;                   /* transport / signaling */

    port_t ports[MAX_PORTS]; int nports;
    int n_foreign;                       /* licznik obcych datagramów (do logu) */
    pair_t pairs[MAX_PAIRS];
    int sel;                             /* wybrana para (-1 = brak) */

    char l_ufrag[12], l_pwd[28];
    char r_ufrag[64], r_pwd[130];
    int have_remote;
    uint64_t tiebreak;

    pthread_t thread;
    int thread_started;
    volatile int stopping;
    int state, err;
    uint32_t t0_sec;
    uint32_t start_ms, last_rx_ms, last_state_ms;

    /* kolejka sygnalizacji przychodzącej */
    pthread_mutex_t sq_mx;
    uint8_t *sq[SIGQ]; int sq_len[SIGQ]; int sq_n;

    /* audio */
    OpusEncoder *enc;
    OpusDecoder *dec;
    int16_t cap[CAP_RING];
    int cap_head, cap_tail;
    pthread_mutex_t cap_mx;
    pthread_mutex_t jb_mx;
    jb_t jb[JB_SIZE];
    int jb_started;
    int32_t next_pts;
    uint32_t jb_first_arr;
    int last_ms, plc_run;
    int16_t fifo[FIFO_SIZE];
    int fifo_pos, fifo_len;
    int muted, peer_muted, mute_dirty;
    int rtp_have_first;
    uint32_t rtp_first_ts;
    uint16_t out_seq;
    uint16_t out_twseq;                       /* numer transport-wide-cc (rozszerzenie RTP id 1) */
    uint32_t out_ts, out_ssrc, in_ssrc;
    int out_marker;
    uint32_t last_audio_media_ms, last_ice_ms;
    /* informacja zwrotna transport-cc (RTCP), jak odbiornik WebRTC */
    struct { uint16_t seq; uint32_t t; } twcc[128];
    int ntwcc;
    uint32_t twcc_last_ms;
    uint8_t twcc_count;

    /* diagnostyka */
    uint32_t n_cand_rx, n_cand_refl, n_cand_other, n_cand_bad_id;
    uint32_t n_stun_tx, n_stun_req_rx, n_stun_resp_rx, n_stun_bad, n_stun_err;
    uint32_t n_ec_rx, n_ec_unk, n_rtp_tx, n_rtp_rx, n_rtcp_rx, n_sig_rx, n_sig_tx;
    uint32_t n_dgram_rx, n_dgram_tx, n_lost;
    uint32_t cap_total, play_total, n_dec_ok, n_dec_err, n_rtp_badpt, n_rtp_badssrc;   /* diagnostyka dźwięku */
    int cap_peak, play_peak, dec_last_err;
    uint32_t n_msg_t[12], n_rtp_bad;
    uint32_t rt_sr, rt_rr, rt_cc, rt_fb, rt_ps, rt_oth, rt_sr_pkts, rt_rr_lost;   /* zawartość RTCP od rozmówcy */
    int peer_ms;                                                              /* surowy bajt RemoteMediaState */
    int remote_ids[16], n_remote_ids;
};

static uint32_t now_ms(acg *g)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint32_t)(((uint32_t)tv.tv_sec - g->t0_sec) * 1000u + (uint32_t)tv.tv_usec / 1000u) + 1;
}

static void set_state(acg *g, int st, int err)
{
    if (g->state == st && g->err == err) return;
    g->state = st;
    g->err = err;
    logf_("stan %d (blad %d)", st, err);
    if (g->scb) g->scb(g->ud, st, err);
}

static void fail(acg *g, int err) { set_state(g, ACG_STATE_FAILED, err); }

/* ---------- wysyłanie przez serwer pośredniczący ("reflector") ---------- */

static void refl_send(acg *g, int pi, uint32_t rtag, const uint8_t *d, int n)
{
    port_t *p = &g->ports[pi];
    uint8_t out[MAX_PKT + 64];
    int total;
    if (p->sock < 0 || n > MAX_PKT) return;
    memcpy(out, p->tag12, 12);
    wle32(out + 12, rtag);
    wle32(out + 16, p->my_tag);
    wbe32(out + 20, (uint32_t)n);
    memcpy(out + 24, d, (size_t)n);
    total = 24 + n;
    while (total % 4) out[total++] = 0;
    sendto(p->sock, (const char *)out, (size_t)total, 0, (struct sockaddr *)&p->addr, sizeof(p->addr));
    g->n_dgram_tx++;
}

static void refl_hello(acg *g, int pi)
{
    port_t *p = &g->ports[pi];
    uint8_t b[40];
    memcpy(b, p->tag12, 12);
    wle32(b + 12, p->my_tag);
    memset(b + 16, 0xff, 12);
    b[28] = 0xfe;
    memset(b + 29, 0xff, 3);
    wbe32(b + 32, 0);
    wbe32(b + 36, 123);
    if (p->sock >= 0) sendto(p->sock, (const char *)b, 40, 0, (struct sockaddr *)&p->addr, sizeof(p->addr));
    p->hellos++;
    p->last_hello = now_ms(g);
}

/* ---------- sygnalizacja: wysyłanie ---------- */

static void sig_emit(acg *g, const uint8_t *d, int n)
{
    if (n <= 0) return;
    g->n_sig_tx++;
    if (g->sigcb) g->sigcb(g->ud, d, n);
}

static int put_str(uint8_t *b, const char *s)
{
    int l = (int)strlen(s);
    wbe32(b, (uint32_t)l);
    memcpy(b + 4, s, (size_t)l);
    return 4 + l;
}

static void send_candidate(acg *g, int pi)
{
    port_t *p = &g->ports[pi];
    char cand[256];
    uint8_t body[600], out[EC_LIMIT_SIGNALING + MAX_PKT];
    int o = 0, n;
    uint32_t prio = (2u << 24) | ((uint32_t)(65535 - pi) << 8) | 255u;
    snprintf(cand, sizeof(cand), "candidate:%u 1 udp %u reflector-%d-%u.reflector %d typ relay generation 0 ufrag %s network-id %d",
             (unsigned)(1000 + p->id), (unsigned)prio, p->id, (unsigned)p->my_tag, (int)ntohs(p->addr.sin_port), g->l_ufrag, pi + 1);
    body[o++] = 1;
    o += put_str(body + o, cand);
    o += put_str(body + o, g->l_ufrag);
    o += put_str(body + o, g->l_pwd);
    n = ec_send_reliable(&g->ec_s_, MSG_CANDIDATES, body, o, out, now_ms(g));
    if (n > 0) sig_emit(g, out, n);
    p->cand_sent = 1;
    logf_("kandydat: %s", cand);
}

static void send_media_state(acg *g)
{
    uint8_t body[1], out[MAX_PKT + 64];
    int n;
    body[0] = (uint8_t)(g->muted ? 0 : 1);                  /* audio: Muted=0, Active=1; wideo: Inactive=0 */
    n = ec_send_reliable(&g->ec_t_, MSG_MEDIA_STATE, body, 1, out, now_ms(g));
    if (n > 0 && g->sel >= 0) refl_send(g, g->pairs[g->sel].port, g->pairs[g->sel].rtag, out, n);
    g->mute_dirty = 0;
}

/* ---------- pary ICE ---------- */

static int pair_find(acg *g, int port, uint32_t rtag)
{
    int i;
    for (i = 0; i < MAX_PAIRS; i++) if (g->pairs[i].used && g->pairs[i].port == port && g->pairs[i].rtag == rtag) return i;
    return -1;
}

static int pair_add(acg *g, int port, uint32_t rtag)
{
    int i = pair_find(g, port, rtag);
    if (i >= 0) return i;
    for (i = 0; i < MAX_PAIRS; i++) if (!g->pairs[i].used) break;
    if (i == MAX_PAIRS) return -1;
    memset(&g->pairs[i], 0, sizeof(pair_t));
    g->pairs[i].used = 1;
    g->pairs[i].port = port;
    g->pairs[i].rtag = rtag;
    g->pairs[i].trigger = 1;
    logf_("para ICE %d: serwer id=%d tag=%u", i, g->ports[port].id, (unsigned)rtag);
    return i;
}

static int port_by_id(acg *g, int id)
{
    int i;
    for (i = 0; i < g->nports; i++) if (g->ports[i].id == id) return i;
    return -1;
}

static void handle_candidates(acg *g, const uint8_t *b, int n)
{
    int o = 0, cnt, i;
    char ufrag[64] = "", pwd[130] = "";
    char cands[16][300];
    int ncand = 0;
    if (n < 1) return;
    cnt = b[o++];
    for (i = 0; i < cnt; i++) {
        uint32_t l = rbe32(b + o);
        o += 4;
        if (ncand < 16) {
            int cl = (int)l < 299 ? (int)l : 299;
            memcpy(cands[ncand], b + o, (size_t)cl);
            cands[ncand][cl] = 0;
            ncand++;
        }
        o += (int)l;
    }
    {
        uint32_t l = rbe32(b + o); o += 4;
        if (l < sizeof(ufrag)) { memcpy(ufrag, b + o, l); ufrag[l] = 0; }
        o += (int)l;
        l = rbe32(b + o); o += 4;
        if (l < sizeof(pwd)) { memcpy(pwd, b + o, l); pwd[l] = 0; }
    }
    if (!g->have_remote && ufrag[0] && pwd[0]) {
        snprintf(g->r_ufrag, sizeof(g->r_ufrag), "%s", ufrag);
        snprintf(g->r_pwd, sizeof(g->r_pwd), "%s", pwd);
        g->have_remote = 1;
        logf_("zdalne ICE: ufrag=%s", ufrag);
    }
    for (i = 0; i < ncand; i++) {
        int id = 0, port = 0, k;
        unsigned tag = 0;
        char addr[160];
        const char *h;
        g->n_cand_rx++;
        logf_("kandydat zdalny: %s", cands[i]);
        /* "candidate:<f> <comp> <proto> <prio> <addr> <port> typ <type> ..." */
        {
            char f[100], proto[16];
            unsigned comp, prio;
            if (sscanf(cands[i], "candidate:%99s %u %15s %u %159s %d", f, &comp, proto, &prio, addr, &port) < 6) { g->n_cand_other++; continue; }
        }
        h = addr;
        if (strncmp(h, "reflector-", 10) == 0 && sscanf(h, "reflector-%d-%u.reflector", &id, &tag) == 2 && tag != 0) {
            int pi = port_by_id(g, id);
            g->n_cand_refl++;
            for (k = 0; k < g->n_remote_ids && g->remote_ids[k] != id; k++) {}
            if (k == g->n_remote_ids && k < 16) g->remote_ids[g->n_remote_ids++] = id;
            if (pi < 0) { g->n_cand_bad_id++; logf_("kandydat zdalny: nieznany id serwera %d", id); continue; }
            pair_add(g, pi, tag);
        } else {
            g->n_cand_other++;
        }
    }
}

static void handle_rtp(acg *g, const uint8_t *d, int n);

static void on_message(void *ud, int sig, int type, const uint8_t *body, int blen)
{
    acg *g = (acg *)ud;
    if (!sig && type >= 1 && type <= 10) g->n_msg_t[type]++;
    switch (type) {
    case MSG_CANDIDATES: handle_candidates(g, body, blen); break;
    case MSG_MEDIA_STATE:
        if (blen >= 1) {
            int pm = (body[0] & 1) ? 0 : 1;
            g->peer_ms = body[0];
            if (pm != g->peer_muted) { g->peer_muted = pm; logf_("rozmowca: wyciszony=%d", pm); }
        }
        break;
    case MSG_AUDIO: handle_rtp(g, body, blen); break;
    case MSG_VIDEO_FORMATS: logf_("(kanal %s) formaty wideo rozmowcy", sig ? "sygn" : "transp"); break;
    default: break;
    }
}

/* ---------- STUN: wysyłanie ---------- */

static void rand_txid(uint8_t t[12]) { tg_random(t, 12); }

static void send_check(acg *g, int pi, uint32_t now)
{
    pair_t *p = &g->pairs[pi];
    stunbuf s;
    uint8_t tx[12], v[8];
    char user[160];
    uint32_t prio = (110u << 24) | (65535u << 8) | 255u;
    if (!g->have_remote) return;
    rand_txid(tx);
    memcpy(p->tx[p->ntx % 4], tx, 12);
    p->ntx++;
    st_begin(&s, ST_BINDING_REQ, tx);
    snprintf(user, sizeof(user), "%s:%s", g->r_ufrag, g->l_ufrag);
    st_attr(&s, SA_USERNAME, user, (int)strlen(user));
    wbe32(v, prio);
    st_attr(&s, SA_PRIORITY, v, 4);
    wbe32(v, (uint32_t)(g->tiebreak >> 32));
    wbe32(v + 4, (uint32_t)g->tiebreak);
    st_attr(&s, g->is_outgoing ? SA_ICE_CONTROLLING : SA_ICE_CONTROLLED, v, 8);
    if (g->is_outgoing && (p->got_resp || p->got_req)) { st_attr(&s, SA_USE_CAND, NULL, 0); p->nominated = 1; }
    st_finish(&s, g->r_pwd);
    refl_send(g, p->port, p->rtag, s.b, s.n);
    p->sent++;
    p->last_sent_ms = now;
    g->n_stun_tx++;
}

static void send_check_response(acg *g, int port, uint32_t rtag, const st_info *info)
{
    stunbuf s;
    uint8_t v[8];
    const struct sockaddr_in *a = &g->ports[port].addr;
    uint32_t ip = ntohl(a->sin_addr.s_addr);
    st_begin(&s, ST_BINDING_OK, info->txid);
    v[0] = 0; v[1] = 1;
    wbe16(v + 2, (uint32_t)(ntohs(a->sin_port) ^ (STUN_COOKIE >> 16)));
    wbe32(v + 4, ip ^ STUN_COOKIE);
    st_attr(&s, SA_XOR_MAPPED, v, 8);
    st_finish(&s, g->l_pwd);
    refl_send(g, port, rtag, s.b, s.n);
}

static void stun_in(acg *g, int port, uint32_t rtag, const uint8_t *m, int n, uint32_t now)
{
    st_info info;
    int pi;
    if (st_parse(m, n, &info) < 0) { g->n_stun_bad++; return; }
    if (info.type == ST_BINDING_REQ) {
        char expect[100];
        int el;
        g->n_stun_req_rx++;
        el = snprintf(expect, sizeof(expect), "%s:", g->l_ufrag);
        if (!info.user || info.userlen < el || memcmp(info.user, expect, (size_t)el) != 0) { g->n_stun_bad++; logf_("STUN zadanie: zla nazwa uzytkownika"); return; }
        if (!st_check_integrity(m, n, &info, g->l_pwd)) { g->n_stun_bad++; logf_("STUN zadanie: zly MESSAGE-INTEGRITY"); return; }
        pi = pair_add(g, port, rtag);
        if (pi < 0) return;
        if (!g->pairs[pi].got_req) logf_("para %d: pierwsze zadanie STUN od rozmowcy%s", pi, info.use_cand ? " (USE-CANDIDATE)" : "");
        g->pairs[pi].got_req = 1;
        if (!g->pairs[pi].got_resp) g->pairs[pi].trigger = 1;        /* sprawdzenie wyzwolone (jak w RFC 5245) */
        g->pairs[pi].last_rx_ms = now;
        if (info.use_cand) g->pairs[pi].nominated = 1;
        if ((info.controlling && g->is_outgoing) || (info.controlled && !g->is_outgoing)) logf_("konflikt rol ICE (zdalne: %s)", info.controlling ? "controlling" : "controlled");
        send_check_response(g, port, rtag, &info);
        g->last_rx_ms = now;
    } else if (info.type == ST_BINDING_OK || info.type == ST_BINDING_ERR) {
        int i, k;
        pi = -1;
        for (i = 0; i < MAX_PAIRS && pi < 0; i++) {
            if (!g->pairs[i].used || g->pairs[i].port != port || g->pairs[i].rtag != rtag) continue;
            for (k = 0; k < 4 && k < g->pairs[i].ntx; k++) if (memcmp(g->pairs[i].tx[k], info.txid, 12) == 0) { pi = i; break; }
        }
        if (pi < 0) {
            /* odpowiedź od innego tagu niż zapytanie? szukamy po samym txid */
            for (i = 0; i < MAX_PAIRS && pi < 0; i++) {
                int kk;
                if (!g->pairs[i].used) continue;
                for (kk = 0; kk < 4 && kk < g->pairs[i].ntx; kk++) if (memcmp(g->pairs[i].tx[kk], info.txid, 12) == 0) { pi = i; break; }
            }
            if (pi < 0) { g->n_stun_bad++; return; }
        }
        if (info.type == ST_BINDING_ERR) { g->n_stun_err++; logf_("para %d: blad STUN %d", pi, info.errcode); return; }
        if (g->have_remote && !st_check_integrity(m, n, &info, g->r_pwd)) { g->n_stun_bad++; logf_("odpowiedz STUN: zly MESSAGE-INTEGRITY"); return; }
        g->n_stun_resp_rx++;
        if (!g->pairs[pi].got_resp) logf_("para %d: odpowiedz STUN - polaczenie dziala", pi);
        g->pairs[pi].got_resp = 1;
        g->pairs[pi].last_rx_ms = now;
        g->last_rx_ms = now;
    } else {
        g->n_stun_bad++;
    }
}

/* ---------- odbiór z serwera pośredniczącego ---------- */

static void handle_datagram(acg *g, int pi, const uint8_t *d, int n)
{
    port_t *p = &g->ports[pi];
    uint32_t now = now_ms(g), stag, dlen;
    g->n_dgram_rx++;
    p->rx_pkts++;
    if (n < 16 || memcmp(d, p->tag12, 12) != 0) {
        /* diagnostyka: pierwsze obce datagramy (np. inny format odpowiedzi serwera) */
        if (g->n_foreign++ < 4) {
            char hx[100];
            int k, m = n < 40 ? n : 40;
            for (k = 0; k < m; k++) snprintf(hx + k * 2, 3, "%02x", d[k]);
            logf_("obcy datagram z portu %d (id=%d), dlugosc %d: %s", pi, p->id, n, m ? hx : "");
        }
        return;
    }
    if (!p->ready) {
        p->ready = 1;
        logf_("serwer id=%d (%s:%d) odpowiada, moj tag=%u", p->id, inet_ntoa(p->addr.sin_addr), (int)ntohs(p->addr.sin_port), (unsigned)p->my_tag);
    }
    if (n <= 24) return;
    {
        int k, special = 1;
        if (n >= 28) { for (k = 0; k < 12; k++) if (d[16 + k] != 0xff) { special = 0; break; } }
        else special = 0;
        if (special) return;
    }
    stag = rle32(d + 16);
    dlen = rbe32(d + 20);
    if (dlen > (uint32_t)(n - 24)) return;
    {
        const uint8_t *pl = d + 24;
        int pn = (int)dlen;
        if (is_stun(pl, pn)) { stun_in(g, pi, stag, pl, pn, now); return; }
        /* pakiet zaszyfrowany transportu */
        if (pn >= 21) {
            if (ec_receive(&g->ec_t_, pl, pn, now, on_message, g)) {
                int i = pair_find(g, pi, stag);
                g->n_ec_rx++;
                g->last_rx_ms = now;
                if (i < 0) i = pair_add(g, pi, stag);
                if (i >= 0) { g->pairs[i].last_rx_ms = now; if (!g->pairs[i].got_resp && !g->pairs[i].got_req) { g->pairs[i].got_req = 1; } }
            } else {
                g->n_ec_unk++;
                if (g->n_ec_unk <= 3) logf_("pakiet transportu nie rozszyfrowany (dlugosc %d, zle skroty %u)", pn, (unsigned)g->ec_t_.n_bad_hash);
            }
        }
    }
}

/* ---------- RTP / dźwięk ---------- */

static void jb_put(acg *g, int32_t pts, const uint8_t *d, int len, uint32_t arr)
{
    int i, free_i = -1, oldest = 0;
    if (len <= 0 || len > JB_DATA) return;
    pthread_mutex_lock(&g->jb_mx);
    if (g->jb_started && (int32_t)(pts - g->next_pts) < 0) { pthread_mutex_unlock(&g->jb_mx); return; }
    for (i = 0; i < JB_SIZE; i++) {
        if (g->jb[i].used && g->jb[i].pts == pts) { pthread_mutex_unlock(&g->jb_mx); return; }
        if (!g->jb[i].used && free_i < 0) free_i = i;
        if (g->jb[i].used && (int32_t)(g->jb[i].pts - g->jb[oldest].pts) < 0) oldest = i;
    }
    if (free_i < 0) free_i = oldest;
    g->jb[free_i].used = 1;
    g->jb[free_i].pts = pts;
    g->jb[free_i].len = len;
    g->jb[free_i].arr = arr;
    memcpy(g->jb[free_i].data, d, (size_t)len);
    pthread_mutex_unlock(&g->jb_mx);
}

/* RTCP od rozmówcy: liczymy rodzaje pakietów (SR = on faktycznie coś nadaje, RR, TWCC...) */
static void rtcp_stats(acg *g, const uint8_t *d, int n)
{
    int o = 0;
    while (o + 4 <= n) {
        int pt = d[o + 1], fmt = d[o] & 31, len = 4 * ((int)rbe16(d + o + 2) + 1);
        if (len < 4 || o + len > n) break;
        if (pt == 200) { g->rt_sr++; if (len >= 28) g->rt_sr_pkts = rbe32(d + o + 20); }
        else if (pt == 201) { g->rt_rr++; if (len >= 32) g->rt_rr_lost = rbe32(d + o + 12) & 0xffffff; }
        else if (pt == 205) { if (fmt == 15) g->rt_cc++; else g->rt_fb++; }
        else if (pt == 206) g->rt_ps++;
        else g->rt_oth++;
        o += len;
    }
}

static void handle_rtp(acg *g, const uint8_t *d, int n)
{
    int cc, off, pad = 0, pt, tseq = -1;
    uint32_t ts, ssrc;
    uint32_t now = now_ms(g);
    if (n < 12 || (d[0] & 0xC0) != 0x80) { g->n_rtp_bad++; return; }
    if (d[1] >= 192 && d[1] <= 223) { g->n_rtcp_rx++; rtcp_stats(g, d, n); return; }    /* RTCP: tylko liczymy, co zawiera */
    pt = d[1] & 0x7f;
    cc = d[0] & 0x0f;
    off = 12 + 4 * cc;
    if (d[0] & 0x10) {
        int el;
        if (n < off + 4) { g->n_rtp_bad++; return; }
        el = (int)rbe16(d + off + 2);
        if (n >= off + 4 + 4 * el && rbe16(d + off) == 0xBEDE) {            /* rozszerzenia jednobajtowe */
            int q = off + 4, qe = off + 4 + 4 * el;
            while (q < qe) {
                int id = d[q] >> 4, l = (d[q] & 15) + 1;
                if (d[q] == 0) { q++; continue; }
                if (id == 15 || q + 1 + l > qe) break;
                if (id == 1 && l == 2) tseq = (int)rbe16(d + q + 1);        /* transport-wide-cc, id 1 */
                q += 1 + l;
            }
        }
        off += 4 + 4 * el;
    }
    if (d[0] & 0x20) pad = d[n - 1];
    if (off + pad >= n) { g->n_rtp_bad++; return; }
    ssrc = rbe32(d + 8);
    ts = rbe32(d + 4);
    if (pt != RTP_PT_OPUS) { g->n_rtp_badpt++; if (g->n_rtp_badpt <= 3) logf_("RTP: nieoczekiwany typ ladunku %d", pt); return; }
    if (ssrc != g->in_ssrc) { g->n_rtp_badssrc++; if (g->n_rtp_badssrc <= 3) logf_("RTP: ssrc %u (oczekiwano %u)", (unsigned)ssrc, (unsigned)g->in_ssrc); }
    if (!g->rtp_have_first) { g->rtp_have_first = 1; g->rtp_first_ts = ts; logf_("pierwszy pakiet audio od rozmowcy (%d B)", n - off - pad); }
    g->n_rtp_rx++;
    if (tseq >= 0 && g->ntwcc < 128) { g->twcc[g->ntwcc].seq = (uint16_t)tseq; g->twcc[g->ntwcc].t = now; g->ntwcc++; }
    jb_put(g, (int32_t)(ts - g->rtp_first_ts) / 48, d + off, n - off - pad, now);
}

static int cap_avail(acg *g) { return g->cap_head - g->cap_tail; }

/* RTCP: Transport-wide congestion control feedback (draft-holmer-rmcat-transport-wide-cc-extensions-01) */
static void twcc_flush(acg *g, uint32_t now)
{
    uint8_t rtcp[512], out[MAX_PKT + 64];
    uint16_t first;
    int i, j, n = g->ntwcc, count, o, nchunks, len;
    uint8_t sym[200];
    uint32_t tt[200];
    uint32_t ref, prev_us;
    uint8_t deltas[420];
    int nd = 0;
    if (n == 0 || g->sel < 0) { g->ntwcc = 0; return; }
    /* sortowanie po (rozwiniętym względem pierwszego) numerze */
    first = g->twcc[0].seq;
    for (i = 0; i < n; i++) if ((int16_t)(g->twcc[i].seq - first) < 0) first = g->twcc[i].seq;
    {
        int maxrel = 0;
        for (i = 0; i < n; i++) { int r = (int)(uint16_t)(g->twcc[i].seq - first); if (r > maxrel) maxrel = r; }
        count = maxrel + 1;
    }
    if (count > 200) { g->ntwcc = 0; return; }
    memset(sym, 0, sizeof(sym));
    for (i = 0; i < n; i++) { int r = (int)(uint16_t)(g->twcc[i].seq - first); tt[r] = g->twcc[i].t; sym[r] = 1; }
    {
        int fi = 0;
        while (fi < count && !sym[fi]) fi++;
        ref = tt[fi] / 64;
        prev_us = ref * 64 * 4;                                       /* w jednostkach 250 µs */
    }
    for (j = 0; j < count; j++) {
        int32_t d;
        if (!sym[j]) continue;
        d = (int32_t)(tt[j] * 4 - prev_us);
        prev_us = tt[j] * 4;
        if (d >= 0 && d <= 255) { sym[j] = 1; deltas[nd++] = (uint8_t)d; }
        else {
            if (d > 32767) d = 32767;
            if (d < -32768) d = -32768;
            sym[j] = 2;
            deltas[nd++] = (uint8_t)((uint16_t)d >> 8);
            deltas[nd++] = (uint8_t)((uint16_t)d & 0xff);
        }
    }
    o = 0;
    rtcp[o++] = 0x8F;                                               /* V=2, P=0, FMT=15 */
    rtcp[o++] = 205;                                                /* RTPFB */
    o += 2;                                                         /* długość uzupełnimy później */
    wbe32(rtcp + o, g->out_ssrc); o += 4;
    wbe32(rtcp + o, g->in_ssrc); o += 4;
    wbe16(rtcp + o, first); o += 2;
    wbe16(rtcp + o, (uint32_t)count); o += 2;
    rtcp[o++] = (uint8_t)(ref >> 16); rtcp[o++] = (uint8_t)(ref >> 8); rtcp[o++] = (uint8_t)ref;
    rtcp[o++] = g->twcc_count++;
    nchunks = (count + 6) / 7;
    for (i = 0; i < nchunks; i++) {
        uint32_t ch = 0xC000u;                                      /* wektor statusów, symbole 2-bitowe */
        for (j = 0; j < 7; j++) {
            int idx = i * 7 + j;
            uint32_t sy = idx < count ? sym[idx] : 0;
            ch |= sy << (12 - 2 * j);
        }
        wbe16(rtcp + o, ch); o += 2;
    }
    memcpy(rtcp + o, deltas, (size_t)nd); o += nd;
    while (o % 4) rtcp[o++] = 0;
    wbe16(rtcp + 2, (uint32_t)(o / 4 - 1));
    len = ec_send_data(&g->ec_t_, MSG_AUDIO, rtcp, o, out, now);
    if (len > 0) refl_send(g, g->pairs[g->sel].port, g->pairs[g->sel].rtag, out, len);
    g->ntwcc = 0;
    g->twcc_last_ms = now;
}

static void send_rtp(acg *g, const uint8_t *opus, int n, uint32_t now)
{
    uint8_t rtp[MAX_PKT], out[MAX_PKT + 64];
    int len;
    if (g->sel < 0 || n <= 0 || n > 1200) return;
    /* jak prawdziwy tgcalls: nagłówek RTP z rozszerzeniem transport-wide-cc (id 1, 2 bajty) —
       dzięki niemu rozmówca odsyła raporty zwrotne (TWCC), a my widzimy, że odbiera nasz dźwięk */
    rtp[0] = 0x90;
    rtp[1] = (uint8_t)(RTP_PT_OPUS | (g->out_marker ? 0x80 : 0));
    g->out_marker = 0;
    wbe16(rtp + 2, g->out_seq);
    wbe32(rtp + 4, g->out_ts);
    wbe32(rtp + 8, g->out_ssrc);
    rtp[12] = 0xBE; rtp[13] = 0xDE; rtp[14] = 0; rtp[15] = 1;          /* profil jednobajtowy, 1 słowo */
    rtp[16] = 0x11;                                                   /* id 1, długość 2 bajty */
    rtp[17] = (uint8_t)(g->out_twseq >> 8);
    rtp[18] = (uint8_t)(g->out_twseq & 0xff);
    rtp[19] = 0;
    memcpy(rtp + 20, opus, (size_t)n);
    g->out_seq++;
    g->out_twseq++;
    g->out_ts += (uint32_t)(FRAME_MS * 48);
    len = ec_send_data(&g->ec_t_, MSG_AUDIO, rtp, 20 + n, out, now);
    if (len > 0) { refl_send(g, g->pairs[g->sel].port, g->pairs[g->sel].rtag, out, len); g->n_rtp_tx++; }
}

static void encode_pending(acg *g, uint32_t now)
{
    while (g->sel >= 0 && !g->muted && !g->stopping) {
        int16_t frame[FRAME_SAMPLES];
        uint8_t pkt[400];
        int avail, i, nbytes;
        pthread_mutex_lock(&g->cap_mx);
        avail = cap_avail(g);
        if (avail < FRAME_SAMPLES) { pthread_mutex_unlock(&g->cap_mx); break; }
        if (avail > FRAME_SAMPLES * 4) g->cap_tail = g->cap_head - FRAME_SAMPLES * 2;
        for (i = 0; i < FRAME_SAMPLES; i++) frame[i] = g->cap[(g->cap_tail + i) % CAP_RING];
        g->cap_tail += FRAME_SAMPLES;
        pthread_mutex_unlock(&g->cap_mx);
        nbytes = opus_encode(g->enc, frame, FRAME_SAMPLES, pkt, 380);
        if (nbytes <= 0) continue;
        send_rtp(g, pkt, nbytes, now);
    }
}

static int decode_next(acg *g)
{
    int i, best = -1, cnt = 0, n = 0;
    int16_t pcm[MAX_DEC_SAMPLES];
    uint32_t now = now_ms(g);
    pthread_mutex_lock(&g->jb_mx);
    for (i = 0; i < JB_SIZE; i++) if (g->jb[i].used) cnt++;
    if (!g->jb_started) {
        int mi = -1;
        uint32_t oldest_arr = 0;
        if (cnt < 1) { pthread_mutex_unlock(&g->jb_mx); return 0; }
        for (i = 0; i < JB_SIZE; i++) if (g->jb[i].used && (mi < 0 || (int32_t)(g->jb[i].pts - g->jb[mi].pts) < 0)) mi = i;
        oldest_arr = g->jb[mi].arr;
        if (cnt < 2 && now - oldest_arr < 90) { pthread_mutex_unlock(&g->jb_mx); return 0; }
        g->next_pts = g->jb[mi].pts;
        g->jb_started = 1;
    }
    if (cnt > 10) {
        int mi = -1;
        for (i = 0; i < JB_SIZE; i++) if (g->jb[i].used && (int32_t)(g->jb[i].pts - g->next_pts) < 0) g->jb[i].used = 0;
        for (i = 0; i < JB_SIZE; i++) if (g->jb[i].used && (mi < 0 || (int32_t)(g->jb[i].pts - g->jb[mi].pts) < 0)) mi = i;
        if (mi >= 0 && (int32_t)(g->jb[mi].pts - g->next_pts) > 600) g->next_pts = g->jb[mi].pts;
    }
    for (i = 0; i < JB_SIZE; i++) if (g->jb[i].used && g->jb[i].pts == g->next_pts) { best = i; break; }
    if (best >= 0) {
        n = opus_decode(g->dec, g->jb[best].data, g->jb[best].len, pcm, MAX_DEC_SAMPLES, 0);
        if (n > 0) g->n_dec_ok++; else { g->n_dec_err++; g->dec_last_err = n; }
        g->jb[best].used = 0;
        g->plc_run = 0;
        if (n > 0) { g->last_ms = n * 1000 / ACG_SAMPLE_RATE; g->next_pts += g->last_ms; }
        else { g->next_pts += FRAME_MS; n = 0; }
    } else {
        int later = -1;
        for (i = 0; i < JB_SIZE; i++) if (g->jb[i].used && (int32_t)(g->jb[i].pts - g->next_pts) > 0 && (later < 0 || (int32_t)(g->jb[i].pts - g->jb[later].pts) < 0)) later = i;
        for (i = 0; i < JB_SIZE; i++) if (g->jb[i].used && (int32_t)(g->jb[i].pts - g->next_pts) < 0) g->jb[i].used = 0;
        if (later >= 0) {
            if ((int32_t)(g->jb[later].pts - g->next_pts) > 400) { g->next_pts = g->jb[later].pts; n = 0; }
            else {
                n = opus_decode(g->dec, NULL, 0, pcm, g->last_ms * (ACG_SAMPLE_RATE / 1000), 0);
                g->next_pts += g->last_ms;
                g->n_lost++;
                if (n < 0) n = 0;
            }
        } else if (g->plc_run < 2 && g->last_ms > 0) {
            n = opus_decode(g->dec, NULL, 0, pcm, g->last_ms * (ACG_SAMPLE_RATE / 1000), 0);
            g->plc_run++;
            if (n < 0) n = 0;
        } else n = 0;
    }
    pthread_mutex_unlock(&g->jb_mx);
    if (n <= 0) return 0;
    if (n > FIFO_SIZE - (g->fifo_len - g->fifo_pos)) n = FIFO_SIZE - (g->fifo_len - g->fifo_pos);
    if (g->fifo_pos > 0) {
        memmove(g->fifo, g->fifo + g->fifo_pos, (size_t)(g->fifo_len - g->fifo_pos) * 2);
        g->fifo_len -= g->fifo_pos;
        g->fifo_pos = 0;
    }
    memcpy(g->fifo + g->fifo_len, pcm, (size_t)n * 2);
    g->fifo_len += n;
    return 1;
}

/* ---------- wątek ---------- */

static void select_pair(acg *g, uint32_t now)
{
    int i, best = -1, bs = -1;
    for (i = 0; i < MAX_PAIRS; i++) {
        pair_t *p = &g->pairs[i];
        int sc = 0;
        if (!p->used) continue;
        if (p->got_resp && p->got_req) sc = 3;
        else if (p->got_resp) sc = 2;
        else if (p->got_req) sc = 1;
        else continue;
        if (p->last_rx_ms && now - p->last_rx_ms > 6000) continue;        /* nieaktywna */
        if (i == g->sel) sc += 1;                                           /* histereza */
        if (p->nominated) sc += 1;
        if (sc > bs) { bs = sc; best = i; }
    }
    if (bs <= 0) best = -1;
    if (best != g->sel) {
        g->sel = best;
        if (best >= 0) {
            logf_("wybrana para %d (serwer id=%d, tag=%u)", best, g->ports[g->pairs[best].port].id, (unsigned)g->pairs[best].rtag);
            g->mute_dirty = 1;
        } else logf_("brak dzialajacej pary");
    }
}

static void drain_signaling(acg *g)
{
    uint8_t *bufs[SIGQ];
    int lens[SIGQ], n, i;
    pthread_mutex_lock(&g->sq_mx);
    n = g->sq_n;
    for (i = 0; i < n; i++) { bufs[i] = g->sq[i]; lens[i] = g->sq_len[i]; g->sq[i] = NULL; }
    g->sq_n = 0;
    pthread_mutex_unlock(&g->sq_mx);
    for (i = 0; i < n; i++) {
        g->n_sig_rx++;
        if (!ec_receive(&g->ec_s_, bufs[i], lens[i], now_ms(g), on_message, g)) logf_("sygnalizacja: pakiet odrzucony (dlugosc %d, zle skroty %u, format %u)", lens[i], (unsigned)g->ec_s_.n_bad_hash, (unsigned)g->ec_s_.n_bad_fmt);
        free(bufs[i]);
    }
}

static void tick(acg *g, uint32_t now)
{
    int i;
    uint8_t out[EC_LIMIT_SIGNALING + MAX_PKT];
    int n;
    /* powitania serwerów */
    for (i = 0; i < g->nports; i++) {
        port_t *p = &g->ports[i];
        uint32_t every = p->ready ? 10000 : 500;
        if (p->hellos == 0 || now - p->last_hello >= every) refl_hello(g, i);
        if (p->ready && !p->cand_sent) send_candidate(g, i);
    }
    /* sprawdzenia ICE */
    for (i = 0; i < MAX_PAIRS; i++) {
        pair_t *p = &g->pairs[i];
        uint32_t every;
        if (!p->used || !g->have_remote) continue;
        if (!p->got_resp) every = p->sent < 30 ? 250 : 1000;
        else every = 1000;
        if ((p->trigger && now - p->last_sent_ms >= 40) || now - p->last_sent_ms >= every) { p->trigger = 0; send_check(g, i, now); }
    }
    select_pair(g, now);
    /* usługa EncryptedConnection */
    if (g->sel >= 0) {
        n = ec_tick(&g->ec_t_, now, out);
        if (n > 0) refl_send(g, g->pairs[g->sel].port, g->pairs[g->sel].rtag, out, n);
        if (g->mute_dirty) send_media_state(g);
    }
    n = ec_tick(&g->ec_s_, now, out);
    if (n > 0) sig_emit(g, out, n);
    /* stan */
    if (g->sel >= 0) {
        if (g->state != ACG_STATE_ESTABLISHED && g->state != ACG_STATE_RECONNECTING) set_state(g, ACG_STATE_ESTABLISHED, 0);
        else if (g->state == ACG_STATE_RECONNECTING && g->last_rx_ms && now - g->last_rx_ms < 4000) set_state(g, ACG_STATE_ESTABLISHED, 0);
        encode_pending(g, now);
        if (g->ntwcc > 0 && now - g->twcc_last_ms >= 100) twcc_flush(g, now);
    }
    if (g->state == ACG_STATE_WAIT_INIT && g->nports > 0) set_state(g, ACG_STATE_CONNECTING, 0);
    if (g->state != ACG_STATE_ESTABLISHED && g->state != ACG_STATE_RECONNECTING && now - g->start_ms > 30000) { fail(g, ACG_ERR_TIMEOUT); return; }
    if (g->state == ACG_STATE_ESTABLISHED && g->last_rx_ms && now - g->last_rx_ms > 10000) set_state(g, ACG_STATE_RECONNECTING, 0);
    if (g->state == ACG_STATE_RECONNECTING && g->last_rx_ms && now - g->last_rx_ms > 40000) fail(g, ACG_ERR_TIMEOUT);
}

static void *run_thread(void *arg)
{
    acg *g = (acg *)arg;
    uint8_t buf[MAX_PKT + 64];
    uint32_t last_stat = 0;
    while (!g->stopping) {
        fd_set rs;
        struct timeval tv;
        int i, r, maxfd = -1;
        uint32_t now;
        FD_ZERO(&rs);
        for (i = 0; i < g->nports; i++) if (g->ports[i].sock >= 0) { FD_SET(g->ports[i].sock, &rs); if (g->ports[i].sock > maxfd) maxfd = g->ports[i].sock; }
        tv.tv_sec = 0;
        tv.tv_usec = 10000;
        r = select(maxfd + 1, &rs, NULL, NULL, &tv);
        if (g->stopping) break;
        if (r > 0) {
            for (i = 0; i < g->nports; i++) {
                int guard;
                if (g->ports[i].sock < 0 || !FD_ISSET(g->ports[i].sock, &rs)) continue;
                for (guard = 0; guard < 64; guard++) {
                    struct sockaddr_in from;
                    socklen_t fl = sizeof(from);
                    ssize_t n = recvfrom(g->ports[i].sock, (char *)buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl);
                    if (n <= 0) break;
                    if (from.sin_addr.s_addr != g->ports[i].addr.sin_addr.s_addr || from.sin_port != g->ports[i].addr.sin_port) continue;
                    handle_datagram(g, i, buf, (int)n);
                }
            }
        }
        drain_signaling(g);
        now = now_ms(g);
        if (g->state == ACG_STATE_FAILED) { usleep(20000); continue; }
        tick(g, now);
        if (now - last_stat >= 5000) {
            char s[900];
            last_stat = now;
            acg_describe(g, s, sizeof(s));
            logf_("%s", s);
        }
    }
    return NULL;
}

/* ======================================================================
 * API
 * ====================================================================== */
static void rand_str(char *s, int n)
{
    static const char al[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    uint8_t r[64];
    int i;
    tg_random(r, (size_t)n);
    for (i = 0; i < n; i++) s[i] = al[r[i] % 62];
    s[n] = 0;
}

acg *acg_new(const uint8_t key[256], int is_outgoing, acg_state_cb scb, acg_signal_cb sigcb, void *ud)
{
    int e1 = 0, e2 = 0;
    struct timeval tv;
    acg *g = (acg *)calloc(1, sizeof(acg));
    if (!g) return NULL;
    memcpy(g->key, key, 256);
    g->is_outgoing = is_outgoing ? 1 : 0;
    g->scb = scb;
    g->sigcb = sigcb;
    g->ud = ud;
    g->state = ACG_STATE_WAIT_INIT;
    g->sel = -1;
    gettimeofday(&tv, NULL);
    g->t0_sec = (uint32_t)tv.tv_sec;
    g->last_ms = FRAME_MS;
    ec_init(&g->ec_t_, 0, g->key, g->is_outgoing);
    ec_init(&g->ec_s_, 1, g->key, g->is_outgoing);
    rand_str(g->l_ufrag, 8);
    rand_str(g->l_pwd, 24);
    {
        uint8_t r[8];
        tg_random(r, 8);
        g->tiebreak = ((uint64_t)rbe32(r) << 32) | rbe32(r + 4);
    }
    {
        uint8_t r[4];
        tg_random(r, 4);
        g->out_seq = (uint16_t)(((uint32_t)r[0] << 8 | r[1]) & 0x7fff);
        tg_random(r, 4);
        g->out_ts = rbe32(r);
    }
    g->out_ssrc = is_outgoing ? 2u : 1u;                     /* MediaManager: caller wysyła ssrc 2, callee ssrc 1 */
    g->in_ssrc = is_outgoing ? 1u : 2u;
    g->out_marker = 1;
    pthread_mutex_init(&g->cap_mx, NULL);
    pthread_mutex_init(&g->jb_mx, NULL);
    pthread_mutex_init(&g->sq_mx, NULL);
    g->enc = opus_encoder_create(ACG_SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &e1);
    g->dec = opus_decoder_create(ACG_SAMPLE_RATE, 1, &e2);
    if (!g->enc || !g->dec || e1 != OPUS_OK || e2 != OPUS_OK) { acg_free(g); return NULL; }
    opus_encoder_ctl(g->enc, OPUS_SET_BITRATE(24000));
    opus_encoder_ctl(g->enc, OPUS_SET_COMPLEXITY(5));
    opus_encoder_ctl(g->enc, OPUS_SET_VBR(1));
    opus_encoder_ctl(g->enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(g->enc, OPUS_SET_PACKET_LOSS_PERC(5));
    opus_encoder_ctl(g->enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(g->enc, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND));
    return g;
}

int acg_add_reflector(acg *g, int id, const char *ip, int port, const uint8_t peer_tag[16])
{
    port_t *p;
    uint8_t r[4];
    if (!g || g->nports >= MAX_PORTS || !ip || port <= 0 || port > 65535 || id <= 0 || id > 255) return -1;
    p = &g->ports[g->nports];
    memset(p, 0, sizeof(*p));
    p->id = id;
    p->sock = -1;
    p->addr.sin_family = AF_INET;
    p->addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &p->addr.sin_addr) != 1) return -1;
    memcpy(p->tag12, peer_tag, 12);
    do { tg_random(r, 4); p->my_tag = rle32(r); } while (p->my_tag == 0);
    g->nports++;
    return 0;
}

int acg_start(acg *g, char *err, int errlen)
{
    int i;
    if (!g || g->nports == 0) { if (err) snprintf(err, (size_t)errlen, "brak serwerów rozmów"); return -1; }
    for (i = 0; i < g->nports; i++) {
        struct sockaddr_in a;
        int fl;
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) { if (err) snprintf(err, (size_t)errlen, "gniazdo: %d", errno); set_state(g, ACG_STATE_FAILED, ACG_ERR_SOCKET); return -1; }
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) { if (err) snprintf(err, (size_t)errlen, "bind: %d", errno); close(s); set_state(g, ACG_STATE_FAILED, ACG_ERR_SOCKET); return -1; }
        fl = fcntl(s, F_GETFL, 0);
        fcntl(s, F_SETFL, fl | O_NONBLOCK);
#ifdef SO_NOSIGPIPE
        { int one = 1; setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)); }
#endif
        g->ports[i].sock = s;
    }
    g->start_ms = now_ms(g);
    g->stopping = 0;
    {
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setstacksize(&at, 512 * 1024);
        if (pthread_create(&g->thread, &at, run_thread, g) != 0) { pthread_attr_destroy(&at); if (err) snprintf(err, (size_t)errlen, "wątek"); return -1; }
        pthread_attr_destroy(&at);
    }
    g->thread_started = 1;
    logf_("start: %d serwerow, jestem %s, ufrag=%s", g->nports, g->is_outgoing ? "dzwoniacym (controlling)" : "odbierajacym (controlled)", g->l_ufrag);
    return 0;
}

void acg_stop(acg *g)
{
    int i;
    if (!g) return;
    g->stopping = 1;
    if (g->thread_started) { pthread_join(g->thread, NULL); g->thread_started = 0; }
    for (i = 0; i < g->nports; i++) if (g->ports[i].sock >= 0) { close(g->ports[i].sock); g->ports[i].sock = -1; }
}

void acg_free(acg *g)
{
    int i;
    if (!g) return;
    acg_stop(g);
    for (i = 0; i < SIGQ; i++) { free(g->sq[i]); g->sq[i] = NULL; }
    if (g->enc) opus_encoder_destroy(g->enc);
    if (g->dec) opus_decoder_destroy(g->dec);
    pthread_mutex_destroy(&g->cap_mx);
    pthread_mutex_destroy(&g->jb_mx);
    pthread_mutex_destroy(&g->sq_mx);
    memset(g->key, 0, sizeof(g->key));
    free(g);
}

void acg_signaling_in(acg *g, const uint8_t *data, int len)
{
    uint8_t *c;
    if (!g || len <= 0 || len > 20000) return;
    c = (uint8_t *)malloc((size_t)len);
    if (!c) return;
    memcpy(c, data, (size_t)len);
    pthread_mutex_lock(&g->sq_mx);
    if (g->sq_n < SIGQ) { g->sq[g->sq_n] = c; g->sq_len[g->sq_n] = len; g->sq_n++; c = NULL; }
    pthread_mutex_unlock(&g->sq_mx);
    free(c);
}

void acg_set_mute(acg *g, int mute)
{
    if (!g) return;
    mute = mute ? 1 : 0;
    if (g->muted == mute) return;
    g->muted = mute;
    g->mute_dirty = 1;
    if (mute) { pthread_mutex_lock(&g->cap_mx); g->cap_tail = g->cap_head; pthread_mutex_unlock(&g->cap_mx); }
}

int acg_peer_muted(acg *g) { return g ? g->peer_muted : 0; }
int acg_state(acg *g) { return g ? g->state : 0; }

void acg_push_capture(acg *g, const int16_t *pcm, int n)
{
    int i;
    if (!g || g->muted || n <= 0) return;
    for (i = 0; i < n; i++) { int a = pcm[i] < 0 ? -pcm[i] : pcm[i]; if (a > g->cap_peak) g->cap_peak = a; }
    g->cap_total += (uint32_t)n;
    pthread_mutex_lock(&g->cap_mx);
    for (i = 0; i < n; i++) g->cap[(g->cap_head + i) % CAP_RING] = pcm[i];
    g->cap_head += n;
    if (g->cap_head - g->cap_tail > CAP_RING - 1) g->cap_tail = g->cap_head - (CAP_RING - 1);
    if (g->cap_head > 0x40000000) { g->cap_head -= 0x40000000 / CAP_RING * CAP_RING; g->cap_tail -= 0x40000000 / CAP_RING * CAP_RING; }
    pthread_mutex_unlock(&g->cap_mx);
}

void acg_pull_playout(acg *g, int16_t *pcm, int n)
{
    int got = 0;
    if (!g) { memset(pcm, 0, (size_t)n * 2); return; }
    while (got < n) {
        int avail = g->fifo_len - g->fifo_pos, take;
        if (avail <= 0) {
            g->fifo_pos = g->fifo_len = 0;
            if (!decode_next(g)) break;
            continue;
        }
        take = n - got < avail ? n - got : avail;
        memcpy(pcm + got, g->fifo + g->fifo_pos, (size_t)take * 2);
        g->fifo_pos += take;
        got += take;
    }
    if (got < n) memset(pcm + got, 0, (size_t)(n - got) * 2);
    {
        int i;
        for (i = 0; i < got; i++) { int a = pcm[i] < 0 ? -pcm[i] : pcm[i]; if (a > g->play_peak) g->play_peak = a; }
        g->play_total += (uint32_t)n;
    }
}

void acg_describe(acg *g, char *out, int outlen)
{
    int i, ready = 0, pairs = 0, resp = 0, req = 0;
    if (!g) { snprintf(out, (size_t)outlen, "-"); return; }
    for (i = 0; i < g->nports; i++) if (g->ports[i].ready) ready++;
    for (i = 0; i < MAX_PAIRS; i++) if (g->pairs[i].used) { pairs++; if (g->pairs[i].got_resp) resp++; if (g->pairs[i].got_req) req++; }
    snprintf(out, (size_t)outlen,
             "serwery %d/%d, kand.zdalne %u (refl %u, inne %u, zle-id %u), pary %d (odp %d, zad %d), STUN tx %u rx-zad %u rx-odp %u zle %u, transp rx %u (zle-hash %u nie-rozsz %u), sygn rx %u tx %u (zle-hash %u), RTP tx %u rx %u, RTCP %u",
             ready, g->nports, (unsigned)g->n_cand_rx, (unsigned)g->n_cand_refl, (unsigned)g->n_cand_other, (unsigned)g->n_cand_bad_id, pairs, resp, req,
             (unsigned)g->n_stun_tx, (unsigned)g->n_stun_req_rx, (unsigned)g->n_stun_resp_rx, (unsigned)g->n_stun_bad,
             (unsigned)g->n_ec_rx, (unsigned)g->ec_t_.n_bad_hash, (unsigned)g->n_ec_unk, (unsigned)g->n_sig_rx, (unsigned)g->n_sig_tx, (unsigned)g->ec_s_.n_bad_hash,
             (unsigned)g->n_rtp_tx, (unsigned)g->n_rtp_rx, (unsigned)g->n_rtcp_rx);
    {
        size_t l = strlen(out);
        if ((int)l < outlen - 1) snprintf(out + l, (size_t)outlen - l, ", mik %u pr / szczyt %d, glosnik %u pr / szczyt %d, dekod ok %u blad %u (%d), zly-pt %u zly-ssrc %u, zgubione %u",
                 (unsigned)g->cap_total, g->cap_peak, (unsigned)g->play_total, g->play_peak, (unsigned)g->n_dec_ok, (unsigned)g->n_dec_err, g->dec_last_err, (unsigned)g->n_rtp_badpt, (unsigned)g->n_rtp_badssrc, (unsigned)g->n_lost);
    }
}

/* dodatkowe linie diagnostyczne: ICE/STUN, pakiety transportu, typy wiadomości, wybrana para */
void acg_short2(acg *g, char *out, int outlen)
{
    char msg[80];
    int i, o = 0, sel_resp = -1, sel_req = -1, sel_nom = -1, cands = 0;
    if (!g) { snprintf(out, (size_t)outlen, "-"); return; }
    msg[0] = 0;
    for (i = 1; i <= 10 && o < 60; i++) if (g->n_msg_t[i]) o += snprintf(msg + o, sizeof(msg) - (size_t)o, "%d:%u ", i, (unsigned)g->n_msg_t[i]);
    if (g->sel >= 0) { sel_resp = g->pairs[g->sel].got_resp; sel_req = g->pairs[g->sel].got_req; sel_nom = g->pairs[g->sel].nominated; }
    cands = (int)g->n_cand_rx;
    snprintf(out, (size_t)outlen,
             "STUN wys %u zad %u odp %u zle %u\nDGM %u pakiet %u nierozsz %u zlehash %u rtcp %u rtp-zle %u\nMSG %s\nRTCP SR %u RR %u CC %u fb %u ps %u inne %u · SR-pak %u · stan %d\npara %d odp %d zad %d nom %d kand %d",
             (unsigned)g->n_stun_tx, (unsigned)g->n_stun_req_rx, (unsigned)g->n_stun_resp_rx, (unsigned)g->n_stun_bad,
             (unsigned)g->n_dgram_rx, (unsigned)g->n_ec_rx, (unsigned)g->n_ec_unk, (unsigned)g->ec_t_.n_bad_hash, (unsigned)g->n_rtcp_rx, (unsigned)g->n_rtp_bad,
             msg, (unsigned)g->rt_sr, (unsigned)g->rt_rr, (unsigned)g->rt_cc, (unsigned)g->rt_fb, (unsigned)g->rt_ps, (unsigned)g->rt_oth, (unsigned)g->rt_sr_pkts, g->peer_ms,
             g->sel, sel_resp, sel_req, sel_nom, cands);
}

/* krótka linia na ekran rozmowy: pakiety wysłane/odebrane, poziom mikrofonu i głośnika (szczyty od ostatniego odczytu) */
void acg_short(acg *g, char *out, int outlen)
{
    if (!g) { snprintf(out, (size_t)outlen, "-"); return; }
    snprintf(out, (size_t)outlen, "wys %u odb %u · mik %d · gł %d · dek %u/%u",
             (unsigned)g->n_rtp_tx, (unsigned)g->n_rtp_rx, g->cap_peak, g->play_peak, (unsigned)g->n_dec_ok, (unsigned)g->n_dec_err);
    g->cap_peak = 0;
    g->play_peak = 0;
}
