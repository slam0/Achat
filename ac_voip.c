#include "ac_voip.h"
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

/* ---- stałe protokołu (libtgvoip, PrivateDefines.h) ---- */
#define PKT_INIT 1
#define PKT_INIT_ACK 2
#define PKT_STREAM_DATA 4
#define PKT_PING 6
#define PKT_PONG 7
#define PKT_STREAM_DATA_X2 8
#define PKT_STREAM_DATA_X3 9
#define PKT_NOP 14

#define PROTOCOL_VERSION 9
#define MIN_PROTOCOL_VERSION 3
#define CODEC_OPUS 0x4F505553u         /* 'OPUS' */
#define STREAM_TYPE_AUDIO 1
#define STREAM_DATA_FLAG_LEN16 0x40
#define STREAM_DATA_XFLAG_EXTRA_FEC 0x2000
#define STREAM_DATA_XFLAG_FRAGMENTED 0x4000
#define XPFLAG_HAS_EXTRA 1
#define XPFLAG_HAS_RECV_TS 2
#define EXTRA_TYPE_STREAM_FLAGS 1
#define STREAM_FLAG_ENABLED 1
#define STREAM_FLAG_PAUSED 8
#define TLID_REFLECTOR_SELF_INFO 0xc01572c7u

#define MAX_RELAYS 8
#define MAX_RECENT 128
#define FRAME_MS 60
#define FRAME_SAMPLES (ACV_SAMPLE_RATE / 1000 * FRAME_MS)       /* 960 */
#define MAX_DEC_SAMPLES (ACV_SAMPLE_RATE / 1000 * 120)          /* 1920 */
#define CAP_RING 8192
#define JB_SIZE 24
#define FIFO_SIZE 4096
#define MAX_PKT 1500

typedef struct {
    struct sockaddr_in addr;
    uint8_t tag[16];
    uint32_t ping_id_lo, ping_id_hi;     /* ostatni wysłany ping UDP do przekaźnika (8 bajtów) */
    uint32_t ping_sent_ms;
    int pongs;
    int rtt_ms;                          /* 0 = brak */
    uint32_t last_rx_ms;
} relay_t;

typedef struct { int used; int32_t pts; int len; uint8_t data[400]; } jb_t;

struct acv {
    uint8_t key[256];
    int is_outgoing;
    acv_state_cb cb;
    void *ud;

    relay_t relays[MAX_RELAYS];
    int nrelays, cur;

    int sock;
    pthread_t thread;
    int running, thread_started;
    volatile int stopping;

    int state, err;
    uint32_t t0_sec;                     /* początek odliczania czasu (sekundy) */

    /* numeracja pakietów */
    uint32_t out_seq, last_remote_seq, last_remote_ack;
    uint32_t recent_in[MAX_RECENT];
    int recent_n;
    int unacked_in;

    int peer_version, got_init, got_init_ack, audio_started, got_stream_data;
    uint32_t init_ack_ms, last_init_ms, last_ping_ms, last_nop_ms, last_rx_ms, start_ms, last_udp_ping_ms;
    int udp_pings_sent;
    uint32_t out_pts;

    /* extra (flagi strumienia: wyciszenie) czekające na potwierdzenie */
    int extra_pending, extra_acked_seq_valid;
    uint32_t extra_first_seq;
    uint8_t extra_data[8];
    int extra_len;
    int muted, peer_muted;

    /* kodek */
    OpusEncoder *enc;
    OpusDecoder *dec;
    int16_t cap[CAP_RING];
    int cap_head, cap_tail;              /* indeksy rosnące, mod CAP_RING przy dostępie */
    pthread_mutex_t cap_mx;

    pthread_mutex_t jb_mx;
    jb_t jb[JB_SIZE];
    int jb_started;
    int32_t next_pts;
    int last_ms;                         /* długość ostatnio zdekodowanej ramki (ms) */
    int plc_run;
    int16_t fifo[FIFO_SIZE];
    int fifo_pos, fifo_len;

    uint32_t n_sent, n_recv, n_lost;
};

static acv_log_cb g_log;
void acv_set_log(acv_log_cb cb) { g_log = cb; }

static void logf_(const char *fmt, ...)
{
    if (!g_log) return;
    char b[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    g_log(b);
}

static uint32_t now_ms(acv *v)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint32_t)(((uint32_t)tv.tv_sec - v->t0_sec) * 1000u + (uint32_t)tv.tv_usec / 1000u);
}

static void w16(uint8_t *p, uint32_t x) { p[0] = (uint8_t)x; p[1] = (uint8_t)(x >> 8); }
static void w32(uint8_t *p, uint32_t x) { p[0] = (uint8_t)x; p[1] = (uint8_t)(x >> 8); p[2] = (uint8_t)(x >> 16); p[3] = (uint8_t)(x >> 24); }
static uint32_t r16(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }
static uint32_t r32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

static int seqgt(uint32_t a, uint32_t b)
{
    return ((a > b) && (a - b <= 0x7FFFFFFFu)) || ((a < b) && (b - a > 0x7FFFFFFFu));
}

/* ---------- stan ---------- */

static void set_state(acv *v, int st, int err)
{
    if (v->state == st && v->err == err) return;
    v->state = st;
    v->err = err;
    logf_("stan %d (blad %d)", st, err);
    if (v->cb) v->cb(v->ud, st, err);
}

static void fail(acv *v, int err) { set_state(v, ACV_STATE_FAILED, err); }

/* ---------- szyfrowanie (KDF2 z libtgvoip) ---------- */

static void kdf2(const uint8_t *key, const uint8_t msg_key[16], int x, uint8_t aes_key[32], uint8_t aes_iv[32])
{
    uint8_t buf[16 + 36], sa[32], sb[32];
    memcpy(buf, msg_key, 16);
    memcpy(buf + 16, key + x, 36);
    tg_sha256(buf, 52, sa);
    memcpy(buf, key + 40 + x, 36);
    memcpy(buf + 36, msg_key, 16);
    tg_sha256(buf, 52, sb);
    memcpy(aes_key, sa, 8);
    memcpy(aes_key + 8, sb + 8, 16);
    memcpy(aes_key + 24, sa + 24, 8);
    memcpy(aes_iv, sb, 8);
    memcpy(aes_iv + 8, sa + 8, 16);
    memcpy(aes_iv + 24, sb + 24, 8);
}

/* pakiet logiczny (nagłówek + dane) -> bajty do wysłania: tag | msgKey | AES-IGE(len16 | dane | wypełnienie) */
static int seal(acv *v, const relay_t *r, const uint8_t *plain, int len, uint8_t *out)
{
    uint8_t inner[MAX_PKT + 64];
    int total;
    int pad;
    w16(inner, (uint32_t)len);
    memcpy(inner + 2, plain, (size_t)len);
    pad = 16 - (2 + len) % 16;
    if (pad < 16) pad += 16;
    tg_random(inner + 2 + len, (size_t)pad);
    total = 2 + len + pad;
    {
        uint8_t big[32 + MAX_PKT + 64], mk32[32], msg_key[16], ak[32], iv[32];
        int x = v->is_outgoing ? 0 : 8;
        memcpy(big, v->key + 88 + x, 32);
        memcpy(big + 32, inner, (size_t)total);
        tg_sha256(big, (size_t)(32 + total), mk32);
        memcpy(msg_key, mk32 + 8, 16);
        kdf2(v->key, msg_key, x, ak, iv);
        memcpy(out, r->tag, 16);
        memcpy(out + 16, msg_key, 16);
        tg_aes_ige_encrypt(ak, iv, inner, out + 32, (size_t)total);
    }
    return 32 + total;
}

/* odwrotnie; zwraca długość pakietu logicznego albo -1 */
static int unseal(acv *v, const uint8_t *in, int n, uint8_t *plain)
{
    uint8_t dec[MAX_PKT + 64], ak[32], iv[32], big[32 + MAX_PKT + 64], mk32[32];
    int dlen = n - 32, inner_len, x = v->is_outgoing ? 8 : 0;
    if (dlen < 16 || dlen % 16 != 0 || dlen > MAX_PKT) return -1;
    kdf2(v->key, in + 16, x, ak, iv);
    tg_aes_ige_decrypt(ak, iv, in + 32, dec, (size_t)dlen);
    memcpy(big, v->key + 88 + x, 32);
    memcpy(big + 32, dec, (size_t)dlen);
    tg_sha256(big, (size_t)(32 + dlen), mk32);
    if (memcmp(mk32 + 8, in + 16, 16) != 0) return -1;
    inner_len = (int)r16(dec);
    if (inner_len > dlen - 2 || dlen - inner_len < 16) return -1;
    memcpy(plain, dec + 2, (size_t)inner_len);
    return inner_len;
}

/* ---------- wysyłanie ---------- */

static void raw_send(acv *v, int ri, const uint8_t *buf, int len)
{
    relay_t *r = &v->relays[ri];
    if (v->sock < 0) return;
    sendto(v->sock, (const char *)buf, (size_t)len, 0, (struct sockaddr *)&r->addr, sizeof(r->addr));
}

/* składa nagłówek v9 i wysyła do przekaźnika ri (ri < 0: bieżący) */
static void send_packet(acv *v, int type, const uint8_t *payload, int plen, int ri)
{
    uint8_t pkt[MAX_PKT], out[MAX_PKT + 96];
    int o = 0, i, n;
    uint32_t acks = 0, pseq;
    if (ri < 0) ri = v->cur;
    if (v->nrelays == 0 || plen > 1200) return;
    for (i = 0; i < 32; i++) {
        uint32_t want = v->last_remote_seq - (uint32_t)(i + 1);
        int k;
        for (k = 0; k < v->recent_n; k++) if (v->recent_in[k] == want) { acks |= (1u << (31 - i)); break; }
    }
    pseq = ++v->out_seq;
    pkt[o++] = (uint8_t)type;
    w32(pkt + o, v->last_remote_seq); o += 4;
    w32(pkt + o, pseq); o += 4;
    w32(pkt + o, acks); o += 4;
    if (v->extra_pending) {
        pkt[o++] = XPFLAG_HAS_EXTRA;
        pkt[o++] = 1;
        pkt[o++] = (uint8_t)(v->extra_len + 1);
        pkt[o++] = EXTRA_TYPE_STREAM_FLAGS;
        memcpy(pkt + o, v->extra_data, (size_t)v->extra_len); o += v->extra_len;
        if (v->extra_first_seq == 0) v->extra_first_seq = pseq;
    } else {
        pkt[o++] = 0;
    }
    if (plen > 0) { memcpy(pkt + o, payload, (size_t)plen); o += plen; }
    v->unacked_in = 0;
    n = seal(v, &v->relays[ri], pkt, o, out);
    raw_send(v, ri, out, n);
}

static void send_init(acv *v)
{
    uint8_t p[32];
    int o = 0, i;
    w32(p + o, PROTOCOL_VERSION); o += 4;
    w32(p + o, MIN_PROTOCOL_VERSION); o += 4;
    w32(p + o, 0); o += 4;                         /* flagi: bez oszczędzania danych, rozmów grupowych, wideo */
    p[o++] = 1;                                    /* liczba kodeków audio */
    w32(p + o, CODEC_OPUS); o += 4;
    p[o++] = 0;                                    /* dekodery wideo */
    p[o++] = 0;                                    /* maks. rozdzielczość */
    for (i = 0; i < v->nrelays; i++) send_packet(v, PKT_INIT, p, o, i);
}

static void send_init_ack(acv *v, int ri)
{
    uint8_t p[32];
    int o = 0;
    w32(p + o, PROTOCOL_VERSION); o += 4;
    w32(p + o, MIN_PROTOCOL_VERSION); o += 4;
    p[o++] = 1;                                    /* strumienie */
    p[o++] = 1;                                    /* id */
    p[o++] = STREAM_TYPE_AUDIO;
    w32(p + o, CODEC_OPUS); o += 4;
    w16(p + o, FRAME_MS); o += 2;
    p[o++] = 1;                                    /* włączony */
    send_packet(v, PKT_INIT_ACK, p, o, ri);
}

static void send_udp_ping(acv *v, int ri)
{
    relay_t *r = &v->relays[ri];
    uint8_t b[40];
    uint8_t id[8];
    memcpy(b, r->tag, 16);
    w32(b + 16, 0xFFFFFFFFu);
    w32(b + 20, 0xFFFFFFFFu);
    w32(b + 24, 0xFFFFFFFFu);
    w32(b + 28, 0xFFFFFFFEu);                      /* -2 */
    tg_random(id, 8);
    memcpy(b + 32, id, 8);
    r->ping_id_lo = r32(id);
    r->ping_id_hi = r32(id + 4);
    r->ping_sent_ms = now_ms(v);
    raw_send(v, ri, b, 40);
}

static void queue_stream_flags(acv *v)
{
    v->extra_data[0] = 1;                          /* id strumienia */
    w32(v->extra_data + 1, v->muted ? 0u : STREAM_FLAG_ENABLED);
    v->extra_len = 5;
    v->extra_pending = 1;
    v->extra_first_seq = 0;
}

/* ---------- odbiór ---------- */

static int find_relay(acv *v, const struct sockaddr_in *from)
{
    int i;
    for (i = 0; i < v->nrelays; i++)
        if (v->relays[i].addr.sin_addr.s_addr == from->sin_addr.s_addr && v->relays[i].addr.sin_port == from->sin_port) return i;
    return -1;
}

static void jb_put(acv *v, int32_t pts, const uint8_t *d, int len)
{
    int i, free_i = -1, oldest = 0;
    if (len <= 0 || len > (int)sizeof(v->jb[0].data)) return;
    pthread_mutex_lock(&v->jb_mx);
    if (v->jb_started && (int32_t)(pts - v->next_pts) < 0) { pthread_mutex_unlock(&v->jb_mx); return; }       /* spóźniony */
    for (i = 0; i < JB_SIZE; i++) {
        if (v->jb[i].used && v->jb[i].pts == pts) { pthread_mutex_unlock(&v->jb_mx); return; }                 /* duplikat */
        if (!v->jb[i].used && free_i < 0) free_i = i;
        if (v->jb[i].used && (int32_t)(v->jb[i].pts - v->jb[oldest].pts) < 0) oldest = i;
    }
    if (free_i < 0) free_i = oldest;
    v->jb[free_i].used = 1;
    v->jb[free_i].pts = pts;
    v->jb[free_i].len = len;
    memcpy(v->jb[free_i].data, d, (size_t)len);
    pthread_mutex_unlock(&v->jb_mx);
}

static void handle_stream_data(acv *v, int type, const uint8_t *p, int n)
{
    int count = type == PKT_STREAM_DATA_X2 ? 2 : (type == PKT_STREAM_DATA_X3 ? 3 : 1), k, o = 0;
    for (k = 0; k < count; k++) {
        unsigned sid, sdlen;
        uint32_t flags, pts;
        int frag;
        if (o + 2 > n) return;
        sid = p[o++];
        flags = sid & 0xC0;
        sid &= 0x3F;
        if (flags & STREAM_DATA_FLAG_LEN16) { if (o + 2 > n) return; sdlen = r16(p + o); o += 2; }
        else sdlen = p[o++];
        if (o + 4 > n) return;
        pts = r32(p + o); o += 4;
        frag = (sdlen & STREAM_DATA_XFLAG_FRAGMENTED) != 0;
        if (frag) { if (o + 2 > n) return; o += 2; }
        {
            int ec = (sdlen & STREAM_DATA_XFLAG_EXTRA_FEC) != 0;
            sdlen &= 0x7FF;
            if (o + (int)sdlen > n) return;
            if (sid == 1 && !frag) jb_put(v, (int32_t)pts, p + o, (int)sdlen);
            o += (int)sdlen;
            if (ec && k == 0 && count == 1) {                 /* dodatkowa korekcja błędów: pomijamy */
                if (o < n) { int c = p[o++], j; for (j = 0; j < c && o < n; j++) { int dl = p[o++]; o += dl; } }
            }
        }
    }
}

static void handle_extra(acv *v, const uint8_t *d, int len)
{
    if (len >= 6 && d[0] == EXTRA_TYPE_STREAM_FLAGS && d[1] == 1) {
        uint32_t f = r32(d + 2);
        v->peer_muted = (f & STREAM_FLAG_ENABLED) ? 0 : 1;
    }
}

static void process_packet(acv *v, int ri, const uint8_t *p, int n)
{
    int type, o = 0, i, pflags;
    uint32_t ack_id, pseq, acks;
    if (n < 14) return;
    type = p[o++];
    ack_id = r32(p + o); o += 4;
    pseq = r32(p + o); o += 4;
    acks = r32(p + o); o += 4;
    pflags = p[o++];
    (void)acks;

    /* duplikaty i okno odbioru */
    if (v->last_remote_seq == 0 || seqgt(pseq, v->last_remote_seq - MAX_RECENT)) {
        for (i = 0; i < v->recent_n; i++) if (v->recent_in[i] == pseq) return;
        if (v->recent_n >= MAX_RECENT) { memmove(v->recent_in, v->recent_in + 1, (MAX_RECENT - 1) * sizeof(uint32_t)); v->recent_n = MAX_RECENT - 1; }
        v->recent_in[v->recent_n++] = pseq;
        if (seqgt(pseq, v->last_remote_seq)) v->last_remote_seq = pseq;
    } else return;
    v->n_recv++;

    if (pflags & XPFLAG_HAS_EXTRA) {
        int cnt;
        if (o >= n) return;
        cnt = p[o++];
        for (i = 0; i < cnt; i++) {
            int el;
            if (o >= n) return;
            el = p[o++];
            if (o + el > n) return;
            handle_extra(v, p + o, el);
            o += el;
        }
    }
    if (pflags & XPFLAG_HAS_RECV_TS) { if (o + 4 > n) return; o += 4; }

    if (seqgt(ack_id, v->last_remote_ack)) {
        v->last_remote_ack = ack_id;
        if (v->extra_pending && v->extra_first_seq != 0 && (ack_id == v->extra_first_seq || seqgt(ack_id, v->extra_first_seq))) v->extra_pending = 0;
    }

    v->last_rx_ms = now_ms(v);
    v->relays[ri].last_rx_ms = v->last_rx_ms;
    if (v->state == ACV_STATE_RECONNECTING) set_state(v, ACV_STATE_ESTABLISHED, 0);
    v->unacked_in++;

    if (type == PKT_INIT) {
        uint32_t ver, minver;
        if (n - o < 12) return;
        ver = r32(p + o); minver = r32(p + o + 4);
        if (!v->got_init) v->peer_version = (int)ver;
        if (minver > PROTOCOL_VERSION || (int)ver < MIN_PROTOCOL_VERSION || (int)ver < 8) { fail(v, ACV_ERR_INCOMPATIBLE); return; }
        send_init_ack(v, ri);
        if (!v->got_init) {
            v->got_init = 1;
            v->cur = ri;
        }
        if (!v->audio_started && v->got_init_ack) v->audio_started = 1;
    } else if (type == PKT_INIT_ACK) {
        if (!v->got_init_ack) {
            int cnt, k, ok = 0;
            uint32_t ver, minver;
            if (n - o < 9) return;
            ver = r32(p + o); minver = r32(p + o + 4);
            if (minver > PROTOCOL_VERSION || (int)ver < MIN_PROTOCOL_VERSION || (int)ver < 8) { fail(v, ACV_ERR_INCOMPATIBLE); return; }
            v->peer_version = (int)ver;
            cnt = p[o + 8];
            o += 9;
            for (k = 0; k < cnt; k++) {
                int id, st;
                if (o + 9 > n) break;
                id = p[o]; st = p[o + 1];
                (void)id;
                if (st == STREAM_TYPE_AUDIO) ok = 1;
                o += 1 + 1 + 4 + 2 + 1;
            }
            if (!ok) return;
            v->got_init_ack = 1;
            v->init_ack_ms = now_ms(v);
            v->cur = ri;
            logf_("odebrano init ack (wersja %d)", v->peer_version);
            if (v->got_init) v->audio_started = 1;
        }
    } else if (type == PKT_STREAM_DATA || type == PKT_STREAM_DATA_X2 || type == PKT_STREAM_DATA_X3) {
        if (!v->got_stream_data) {
            v->got_stream_data = 1;
            if (v->got_init_ack && v->state != ACV_STATE_ESTABLISHED) set_state(v, ACV_STATE_ESTABLISHED, 0);
        }
        handle_stream_data(v, type, p + o, n - o);
    } else if (type == PKT_PING) {
        uint8_t b[4];
        w32(b, pseq);
        send_packet(v, PKT_PONG, b, 4, ri);
    }
    (void)ack_id;
}

static void handle_datagram(acv *v, const struct sockaddr_in *from, const uint8_t *d, int n)
{
    int ri = find_relay(v, from);
    uint8_t plain[MAX_PKT + 64];
    int len;
    if (ri < 0 || n < 16) return;
    if (memcmp(d, v->relays[ri].tag, 16) != 0) return;
    /* odpowiedzi serwisowe przekaźnika (tag + 12 x 0xFF + tlid) */
    if (n >= 32 && r32(d + 16) == 0xFFFFFFFFu && r32(d + 20) == 0xFFFFFFFFu && r32(d + 24) == 0xFFFFFFFFu) {
        if (n >= 32 + 4 + 8 && r32(d + 28) == TLID_REFLECTOR_SELF_INFO) {
            /* d+32: data(4), d+36: id zapytania(8) */
            if (n >= 44 && r32(d + 36) == v->relays[ri].ping_id_lo && r32(d + 40) == v->relays[ri].ping_id_hi) {
                int rtt = (int)(now_ms(v) - v->relays[ri].ping_sent_ms);
                v->relays[ri].pongs++;
                v->relays[ri].rtt_ms = rtt > 0 ? rtt : 1;
            }
        }
        return;
    }
    if (n < 48) return;
    len = unseal(v, d, n, plain);
    if (len < 0) return;
    process_packet(v, ri, plain, len);
}

/* ---------- Opus: kodowanie z mikrofonu ---------- */

static int cap_avail(acv *v) { return v->cap_head - v->cap_tail; }

static void encode_pending(acv *v)
{
    while (v->audio_started && !v->muted && !v->stopping) {
        int16_t frame[FRAME_SAMPLES];
        uint8_t pkt[MAX_PKT], pay[400 + 16];
        int avail, i, nbytes, o = 0;
        pthread_mutex_lock(&v->cap_mx);
        avail = cap_avail(v);
        if (avail < FRAME_SAMPLES) { pthread_mutex_unlock(&v->cap_mx); break; }
        if (avail > FRAME_SAMPLES * 4) { v->cap_tail = v->cap_head - FRAME_SAMPLES * 2; }          /* nadmiar: gubimy najstarsze */
        for (i = 0; i < FRAME_SAMPLES; i++) frame[i] = v->cap[(v->cap_tail + i) % CAP_RING];
        v->cap_tail += FRAME_SAMPLES;
        pthread_mutex_unlock(&v->cap_mx);
        nbytes = opus_encode(v->enc, frame, FRAME_SAMPLES, pkt, 380);
        if (nbytes <= 0) continue;
        /* strumień 1, długość < 256 -> jeden bajt; inaczej LEN16 */
        if (nbytes > 255) {
            pay[o++] = (uint8_t)(1 | STREAM_DATA_FLAG_LEN16);
            w16(pay + o, (uint32_t)nbytes); o += 2;
        } else {
            pay[o++] = 1;
            pay[o++] = (uint8_t)nbytes;
        }
        w32(pay + o, v->out_pts); o += 4;
        memcpy(pay + o, pkt, (size_t)nbytes); o += nbytes;
        v->out_pts += FRAME_MS;
        send_packet(v, PKT_STREAM_DATA, pay, o, -1);
        v->n_sent++;
    }
}

/* ---------- Opus: odtwarzanie ---------- */

/* dekoduje następną ramkę do fifo; zwraca 1, gdy coś dodano */
static int decode_next(acv *v)
{
    int i, best = -1, cnt = 0, n = 0;
    int16_t pcm[MAX_DEC_SAMPLES];
    pthread_mutex_lock(&v->jb_mx);
    for (i = 0; i < JB_SIZE; i++) if (v->jb[i].used) cnt++;
    if (!v->jb_started) {
        int mi = -1;
        if (cnt < 2) { pthread_mutex_unlock(&v->jb_mx); return 0; }
        for (i = 0; i < JB_SIZE; i++) if (v->jb[i].used && (mi < 0 || (int32_t)(v->jb[i].pts - v->jb[mi].pts) < 0)) mi = i;
        v->next_pts = v->jb[mi].pts;
        v->jb_started = 1;
    }
    /* za duże opóźnienie: przeskakujemy do najnowszych */
    if (cnt > 10) {
        int mi = -1;
        for (i = 0; i < JB_SIZE; i++) if (v->jb[i].used && (int32_t)(v->jb[i].pts - v->next_pts) < 0) v->jb[i].used = 0;
        for (i = 0; i < JB_SIZE; i++) if (v->jb[i].used && (mi < 0 || (int32_t)(v->jb[i].pts - v->jb[mi].pts) < 0)) mi = i;
        if (mi >= 0 && (int32_t)(v->jb[mi].pts - v->next_pts) > 600) v->next_pts = v->jb[mi].pts;
    }
    for (i = 0; i < JB_SIZE; i++) if (v->jb[i].used && v->jb[i].pts == v->next_pts) { best = i; break; }
    if (best >= 0) {
        n = opus_decode(v->dec, v->jb[best].data, v->jb[best].len, pcm, MAX_DEC_SAMPLES, 0);
        v->jb[best].used = 0;
        v->plc_run = 0;
        if (n > 0) { v->last_ms = n * 1000 / ACV_SAMPLE_RATE; v->next_pts += v->last_ms; }
        else { v->next_pts += FRAME_MS; n = 0; }
    } else {
        /* brak ramki: czy są nowsze? to utrata -> ukrywanie błędu i dalej */
        int later = 0;
        for (i = 0; i < JB_SIZE; i++) if (v->jb[i].used && (int32_t)(v->jb[i].pts - v->next_pts) > 0) { later = 1; break; }
        for (i = 0; i < JB_SIZE; i++) if (v->jb[i].used && (int32_t)(v->jb[i].pts - v->next_pts) < 0) v->jb[i].used = 0;
        if (later) {
            n = opus_decode(v->dec, NULL, 0, pcm, v->last_ms * (ACV_SAMPLE_RATE / 1000), 0);
            v->next_pts += v->last_ms;
            v->n_lost++;
            if (n < 0) n = 0;
        } else if (v->plc_run < 2 && v->last_ms > 0) {
            n = opus_decode(v->dec, NULL, 0, pcm, v->last_ms * (ACV_SAMPLE_RATE / 1000), 0);
            v->plc_run++;
            if (n < 0) n = 0;
        } else n = 0;
    }
    pthread_mutex_unlock(&v->jb_mx);
    if (n <= 0) return 0;
    if (n > FIFO_SIZE - v->fifo_len + v->fifo_pos) n = FIFO_SIZE - (v->fifo_len - v->fifo_pos);
    if (v->fifo_pos > 0) {
        memmove(v->fifo, v->fifo + v->fifo_pos, (size_t)(v->fifo_len - v->fifo_pos) * 2);
        v->fifo_len -= v->fifo_pos;
        v->fifo_pos = 0;
    }
    memcpy(v->fifo + v->fifo_len, pcm, (size_t)n * 2);
    v->fifo_len += n;
    return 1;
}

/* ---------- wątek ---------- */

static void *run_thread(void *arg)
{
    acv *v = (acv *)arg;
    uint8_t buf[MAX_PKT + 64];
    while (!v->stopping) {
        fd_set rs;
        struct timeval tv;
        uint32_t now;
        int i, r;
        FD_ZERO(&rs);
        FD_SET(v->sock, &rs);
        tv.tv_sec = 0;
        tv.tv_usec = 10000;
        r = select(v->sock + 1, &rs, NULL, NULL, &tv);
        if (v->stopping) break;
        if (r > 0 && FD_ISSET(v->sock, &rs)) {
            int guard;
            for (guard = 0; guard < 64; guard++) {
                struct sockaddr_in from;
                socklen_t fl = sizeof(from);
                ssize_t n = recvfrom(v->sock, (char *)buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl);
                if (n <= 0) break;
                handle_datagram(v, &from, buf, (int)n);
            }
        }
        now = now_ms(v);
        if (v->state == ACV_STATE_FAILED) { usleep(20000); continue; }
        /* pingi UDP do przekaźników: kilka na starcie */
        if (v->udp_pings_sent < 4 && now - v->last_udp_ping_ms >= 500) {
            for (i = 0; i < v->nrelays; i++) send_udp_ping(v, i);
            v->udp_pings_sent++;
            v->last_udp_ping_ms = now;
            if (v->udp_pings_sent == 2 && !v->got_init && !v->got_init_ack) {
                int best = v->cur, br = 0x7fffffff;
                for (i = 0; i < v->nrelays; i++) if (v->relays[i].rtt_ms > 0 && v->relays[i].rtt_ms < br) { br = v->relays[i].rtt_ms; best = i; }
                v->cur = best;
            }
        }
        /* inicjalizacja */
        if (!v->got_init_ack && now - v->last_init_ms >= 500) {
            send_init(v);
            v->last_init_ms = now;
            if (v->state == ACV_STATE_WAIT_INIT) set_state(v, ACV_STATE_WAIT_INIT_ACK, 0);
        }
        if (v->got_init_ack && v->state == ACV_STATE_WAIT_INIT_ACK && now - v->init_ack_ms >= 1500) set_state(v, ACV_STATE_ESTABLISHED, 0);
        if (v->state != ACV_STATE_ESTABLISHED && v->state != ACV_STATE_RECONNECTING && now - v->start_ms > 30000) { fail(v, ACV_ERR_TIMEOUT); continue; }
        if (v->got_init_ack) {
            if (v->extra_pending && now - v->last_nop_ms >= 300) { send_packet(v, PKT_NOP, NULL, 0, -1); v->last_nop_ms = now; }
            if (now - v->last_ping_ms >= 5000) { send_packet(v, PKT_PING, NULL, 0, -1); v->last_ping_ms = now; }
            if (v->unacked_in > 10 || (v->unacked_in > 0 && now - v->last_nop_ms >= 400)) { send_packet(v, PKT_NOP, NULL, 0, -1); v->last_nop_ms = now; }
            encode_pending(v);
        }
        /* brak ruchu */
        if (v->state == ACV_STATE_ESTABLISHED && v->last_rx_ms && now - v->last_rx_ms > 20000) set_state(v, ACV_STATE_RECONNECTING, 0);
        if (v->state == ACV_STATE_RECONNECTING && v->last_rx_ms && now - v->last_rx_ms > 60000) fail(v, ACV_ERR_TIMEOUT);
    }
    return NULL;
}

/* ---------- API ---------- */

acv *acv_new(const uint8_t key[256], int is_outgoing, acv_state_cb cb, void *ud)
{
    int e1 = 0, e2 = 0;
    struct timeval tv;
    acv *v = (acv *)calloc(1, sizeof(acv));
    if (!v) return NULL;
    memcpy(v->key, key, 256);
    v->is_outgoing = is_outgoing ? 1 : 0;
    v->cb = cb;
    v->ud = ud;
    v->sock = -1;
    v->state = ACV_STATE_WAIT_INIT;
    gettimeofday(&tv, NULL);
    v->t0_sec = (uint32_t)tv.tv_sec;
    v->last_ms = FRAME_MS;
    pthread_mutex_init(&v->cap_mx, NULL);
    pthread_mutex_init(&v->jb_mx, NULL);
    v->enc = opus_encoder_create(ACV_SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &e1);
    v->dec = opus_decoder_create(ACV_SAMPLE_RATE, 1, &e2);
    if (!v->enc || !v->dec || e1 != OPUS_OK || e2 != OPUS_OK) { acv_free(v); return NULL; }
    opus_encoder_ctl(v->enc, OPUS_SET_BITRATE(20000));
    opus_encoder_ctl(v->enc, OPUS_SET_COMPLEXITY(5));
    opus_encoder_ctl(v->enc, OPUS_SET_VBR(1));
    opus_encoder_ctl(v->enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(v->enc, OPUS_SET_PACKET_LOSS_PERC(5));
    opus_encoder_ctl(v->enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(v->enc, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND));
    return v;
}

int acv_add_relay(acv *v, const char *ip, int port, const uint8_t tag[16])
{
    relay_t *r;
    if (!v || v->nrelays >= MAX_RELAYS || !ip || port <= 0 || port > 65535) return -1;
    r = &v->relays[v->nrelays];
    memset(r, 0, sizeof(*r));
    r->addr.sin_family = AF_INET;
    r->addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &r->addr.sin_addr) != 1) return -1;
    memcpy(r->tag, tag, 16);
    v->nrelays++;
    return 0;
}

int acv_start(acv *v, char *err, int errlen)
{
    struct sockaddr_in a;
    int fl;
    if (!v || v->nrelays == 0) { if (err) snprintf(err, (size_t)errlen, "brak serwerów rozmów"); return -1; }
    v->sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (v->sock < 0) { if (err) snprintf(err, (size_t)errlen, "gniazdo: %d", errno); set_state(v, ACV_STATE_FAILED, ACV_ERR_SOCKET); return -1; }
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = 0;
    if (bind(v->sock, (struct sockaddr *)&a, sizeof(a)) < 0) { if (err) snprintf(err, (size_t)errlen, "bind: %d", errno); close(v->sock); v->sock = -1; set_state(v, ACV_STATE_FAILED, ACV_ERR_SOCKET); return -1; }
    fl = fcntl(v->sock, F_GETFL, 0);
    fcntl(v->sock, F_SETFL, fl | O_NONBLOCK);
#ifdef SO_NOSIGPIPE
    { int one = 1; setsockopt(v->sock, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)); }
#endif
    v->start_ms = now_ms(v);
    v->cur = 0;
    v->stopping = 0;
    {
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setstacksize(&at, 256 * 1024);
        if (pthread_create(&v->thread, &at, run_thread, v) != 0) { pthread_attr_destroy(&at); close(v->sock); v->sock = -1; if (err) snprintf(err, (size_t)errlen, "wątek"); return -1; }
        pthread_attr_destroy(&at);
    }
    v->thread_started = 1;
    return 0;
}

void acv_stop(acv *v)
{
    if (!v) return;
    v->stopping = 1;
    if (v->thread_started) { pthread_join(v->thread, NULL); v->thread_started = 0; }
    if (v->sock >= 0) { close(v->sock); v->sock = -1; }
}

void acv_free(acv *v)
{
    if (!v) return;
    acv_stop(v);
    if (v->enc) opus_encoder_destroy(v->enc);
    if (v->dec) opus_decoder_destroy(v->dec);
    pthread_mutex_destroy(&v->cap_mx);
    pthread_mutex_destroy(&v->jb_mx);
    memset(v->key, 0, sizeof(v->key));
    free(v);
}

void acv_set_mute(acv *v, int mute)
{
    if (!v) return;
    mute = mute ? 1 : 0;
    if (v->muted == mute) return;
    v->muted = mute;
    queue_stream_flags(v);
    if (mute) { pthread_mutex_lock(&v->cap_mx); v->cap_tail = v->cap_head; pthread_mutex_unlock(&v->cap_mx); }
}

int acv_peer_muted(acv *v) { return v ? v->peer_muted : 0; }
int acv_state(acv *v) { return v ? v->state : 0; }

void acv_push_capture(acv *v, const int16_t *pcm, int n)
{
    int i;
    if (!v || v->muted || n <= 0) return;
    pthread_mutex_lock(&v->cap_mx);
    for (i = 0; i < n; i++) v->cap[(v->cap_head + i) % CAP_RING] = pcm[i];
    v->cap_head += n;
    if (v->cap_head - v->cap_tail > CAP_RING - 1) v->cap_tail = v->cap_head - (CAP_RING - 1);
    if (v->cap_head > 0x40000000) { v->cap_head -= 0x40000000 / CAP_RING * CAP_RING; v->cap_tail -= 0x40000000 / CAP_RING * CAP_RING; }
    pthread_mutex_unlock(&v->cap_mx);
}

void acv_pull_playout(acv *v, int16_t *pcm, int n)
{
    int got = 0;
    if (!v) { memset(pcm, 0, (size_t)n * 2); return; }
    while (got < n) {
        int avail = v->fifo_len - v->fifo_pos, take;
        if (avail <= 0) {
            v->fifo_pos = v->fifo_len = 0;
            if (!decode_next(v)) break;
            continue;
        }
        take = n - got < avail ? n - got : avail;
        memcpy(pcm + got, v->fifo + v->fifo_pos, (size_t)take * 2);
        v->fifo_pos += take;
        got += take;
    }
    if (got < n) memset(pcm + got, 0, (size_t)(n - got) * 2);
}

void acv_stats(acv *v, uint32_t *sent, uint32_t *recvd, uint32_t *lost)
{
    if (!v) return;
    if (sent) *sent = v->n_sent;
    if (recvd) *recvd = v->n_recv;
    if (lost) *lost = v->n_lost;
}
