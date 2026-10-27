#include "tg_mt.h"
#include "tg_bn.h"
#include "tg_crypto.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#include "tg_keys.inc"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define ID_RPC_RESULT   0xf35c6d01u
#define ID_RPC_ERROR    0x2144ca19u
#define ID_CONTAINER    0x73f1f8dcu
#define ID_NEW_SESSION  0x9ec20908u
#define ID_BAD_SALT     0xedab447bu
#define ID_BAD_MSG      0xa7eff811u
#define ID_ACK          0x62d6b459u
#define ID_PONG         0x347773c5u
#define ID_GZIP         0x3072cfa1u
#define ID_PING         0xf3427b8cu
#define ID_VECTOR       0x1cb5c415u

#define MAX_FRAME (8u * 1024u * 1024u)

typedef struct { uint32_t token; uint64_t msg_id; uint8_t *data; size_t len; } pending_t;

struct tg_conn {
    int fd;
    tg_events ev;
    pthread_mutex_t lock;
    uint8_t auth_key[256];
    uint8_t auth_key_id[8];
    int have_key;
    uint64_t salt, session_id, last_msg_id;
    uint32_t seq;
    int32_t time_offset;
    pending_t *pend; int npend, cap;
    uint32_t next_token;
    uint64_t acks[128]; int nacks;
    volatile int closed;
    long last_rx, last_ping;
    char close_reason[96];
};

static uint8_t gExtraKey[256];
static int gHaveExtraKey = 0;

void tg_add_rsa_key(const uint8_t n[256]) { memcpy(gExtraKey, n, 256); gHaveExtraKey = 1; }

/* ---------------- pomocnicze: bufor TL ---------------- */

typedef struct { uint8_t *p; size_t n, cap; } wbuf;

static void w_put(wbuf *b, const void *d, size_t n)
{
    if (b->n + n > b->cap) {
        size_t nc = b->cap ? b->cap : 512;
        while (nc < b->n + n) nc *= 2;
        b->p = (uint8_t *)realloc(b->p, nc);
        b->cap = nc;
    }
    memcpy(b->p + b->n, d, n);
    b->n += n;
}
static void w_u32(wbuf *b, uint32_t v) { uint8_t x[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) }; w_put(b, x, 4); }
static void w_u64(wbuf *b, uint64_t v) { w_u32(b, (uint32_t)v); w_u32(b, (uint32_t)(v >> 32)); }
static void w_bytes(wbuf *b, const uint8_t *d, size_t n)
{
    size_t hdr;
    if (n < 254) { uint8_t l = (uint8_t)n; w_put(b, &l, 1); hdr = 1; }
    else { uint8_t h[4] = { 254, (uint8_t)n, (uint8_t)(n >> 8), (uint8_t)(n >> 16) }; w_put(b, h, 4); hdr = 4; }
    w_put(b, d, n);
    static const uint8_t z[4] = { 0, 0, 0, 0 };
    size_t pad = ((hdr + n + 3) & ~(size_t)3) - (hdr + n);
    if (pad) w_put(b, z, pad);
}

static uint32_t r32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t r64(const uint8_t *p) { return (uint64_t)r32(p) | ((uint64_t)r32(p + 4) << 32); }
static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static void put64(uint8_t *p, uint64_t v) { put32(p, (uint32_t)v); put32(p + 4, (uint32_t)(v >> 32)); }

/* czyta pole bytes/string z d (długość n); zwraca liczbę zużytych bajtów albo 0 przy błędzie */
static size_t r_bytes(const uint8_t *d, size_t n, const uint8_t **out, size_t *olen)
{
    if (n < 1) return 0;
    size_t len = d[0], hdr = 1;
    if (len == 254) { if (n < 4) return 0; len = (size_t)d[1] | ((size_t)d[2] << 8) | ((size_t)d[3] << 16); hdr = 4; }
    else if (len == 255) return 0;
    size_t total = (hdr + len + 3) & ~(size_t)3;
    if (total > n) return 0;
    *out = d + hdr; *olen = len;
    return total;
}

static void set_err(char *err, int errlen, const char *msg)
{
    if (err && errlen > 0) snprintf(err, (size_t)errlen, "%s", msg);
}

/* ---------------- czas, identyfikatory ---------------- */

static long now_sec(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long)tv.tv_sec;
}

static uint64_t gen_msg_id(tg_conn *c)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    uint64_t sec = (uint64_t)((int64_t)tv.tv_sec + c->time_offset);
    uint64_t frac = (uint64_t)tv.tv_usec * 4294u;
    uint64_t id = (sec << 32) | (frac & 0xfffffffcull);
    if (id <= c->last_msg_id) id = c->last_msg_id + 4;
    c->last_msg_id = id;
    return id;
}

/* ---------------- gniazdo ---------------- */

static int io_send_all(int fd, const uint8_t *p, size_t n)
{
    while (n) {
        ssize_t r = send(fd, p, n, MSG_NOSIGNAL);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

/* 1 = można czytać, 0 = timeout, -1 = błąd */
static int io_wait(int fd, int ms)
{
    fd_set rf;
    struct timeval tv;
    FD_ZERO(&rf);
    FD_SET(fd, &rf);
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms - (int)tv.tv_sec * 1000) * 1000;
    int r = select(fd + 1, &rf, NULL, NULL, &tv);
    if (r < 0) return errno == EINTR ? 0 : -1;
    return r > 0 ? 1 : 0;
}

static int io_recv_all(int fd, uint8_t *p, size_t n, int timeout_ms)
{
    while (n) {
        int w = io_wait(fd, timeout_ms);
        if (w <= 0) return w == 0 ? -2 : -1;
        ssize_t r = recv(fd, p, n, 0);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

/* ramka transportu "intermediate": 4 bajty długości (LE) + dane */
static int frame_send(tg_conn *c, const uint8_t *d, size_t n)
{
    uint8_t *buf = (uint8_t *)malloc(n + 4);
    if (!buf) return -1;
    put32(buf, (uint32_t)n);
    memcpy(buf + 4, d, n);
    int r = io_send_all(c->fd, buf, n + 4);
    free(buf);
    return r;
}

/* czyta ramkę; *out z malloc. Zwraca 0 ok, -1 błąd, -2 timeout, -3 kod błędu serwera (w *code) */
static int frame_recv(tg_conn *c, uint8_t **out, size_t *n, int timeout_ms, int32_t *code)
{
    uint8_t hdr[4];
    int r = io_recv_all(c->fd, hdr, 4, timeout_ms);
    if (r) return r;
    uint32_t len = r32(hdr);
    if (len & 0x80000000u) {                       /* szybkie potwierdzenie (quick ack): 4 bajty tokena, pomijamy */
        *out = NULL; *n = 0;
        return 1;
    }
    if (len > MAX_FRAME) return -1;
    uint8_t *buf = (uint8_t *)malloc(len ? len : 1);
    if (!buf) return -1;
    r = io_recv_all(c->fd, buf, len, 30000);
    if (r) { free(buf); return r; }
    if (len == 4) { if (code) *code = (int32_t)r32(buf); free(buf); return -3; }
    *out = buf; *n = len;
    return 0;
}

/* ---------------- cykl życia ---------------- */

tg_conn *tg_conn_new(const tg_events *ev)
{
    tg_conn *c = (tg_conn *)calloc(1, sizeof(tg_conn));
    if (!c) return NULL;
    c->fd = -1;
    c->ev = *ev;
    pthread_mutex_init(&c->lock, NULL);
    c->next_token = 1;
    return c;
}

void tg_conn_free(tg_conn *c)
{
    if (!c) return;
    if (c->fd >= 0) close(c->fd);
    for (int i = 0; i < c->npend; i++) free(c->pend[i].data);
    free(c->pend);
    pthread_mutex_destroy(&c->lock);
    free(c);
}

int tg_conn_open(tg_conn *c, const char *ip, int port, int timeout_ms, char *err, int errlen)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { set_err(err, errlen, "socket() nie powiodło się"); return -1; }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &sa.sin_addr) != 1) { close(fd); set_err(err, errlen, "zły adres IP"); return -1; }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    if (r < 0 && errno != EINPROGRESS) {
        char m[96]; snprintf(m, sizeof(m), "connect: %s", strerror(errno)); close(fd); set_err(err, errlen, m); return -1;
    }
    if (r < 0) {
        fd_set wf;
        struct timeval tv;
        FD_ZERO(&wf); FD_SET(fd, &wf);
        tv.tv_sec = timeout_ms / 1000; tv.tv_usec = (timeout_ms - (int)tv.tv_sec * 1000) * 1000;
        int s = select(fd + 1, NULL, &wf, NULL, &tv);
        if (s <= 0) { close(fd); set_err(err, errlen, s == 0 ? "upłynął czas łączenia" : "select() nie powiodło się"); return -1; }
        int soerr = 0; socklen_t sl = sizeof(soerr);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
        if (soerr) { char m[96]; snprintf(m, sizeof(m), "connect: %s", strerror(soerr)); close(fd); set_err(err, errlen, m); return -1; }
    }
    fcntl(fd, F_SETFL, fl);
    c->fd = fd;
    c->closed = 0;
    c->last_rx = now_sec();
    c->last_ping = c->last_rx;
    static const uint8_t init[4] = { 0xee, 0xee, 0xee, 0xee };
    if (io_send_all(fd, init, 4)) { set_err(err, errlen, "nie udało się wysłać nagłówka transportu"); return -1; }
    uint8_t sid[8];
    tg_random(sid, 8);
    memcpy(&c->session_id, sid, 8);
    c->seq = 0;
    return 0;
}

void tg_conn_close(tg_conn *c)
{
    c->closed = 1;
    if (c->fd >= 0) shutdown(c->fd, SHUT_RDWR);
}

int tg_conn_is_open(tg_conn *c) { return c->fd >= 0 && !c->closed; }

static void key_ids(tg_conn *c)
{
    uint8_t h[20];
    tg_sha1(c->auth_key, 256, h);
    memcpy(c->auth_key_id, h + 12, 8);
    c->have_key = 1;
}

void tg_conn_set_auth(tg_conn *c, const uint8_t key[256], uint64_t salt, int32_t time_offset)
{
    memcpy(c->auth_key, key, 256);
    c->salt = salt;
    c->time_offset = time_offset;
    key_ids(c);
}

int tg_conn_get_auth(tg_conn *c, uint8_t key[256], uint64_t *salt, int32_t *time_offset)
{
    if (!c->have_key) return 0;
    memcpy(key, c->auth_key, 256);
    *salt = c->salt;
    *time_offset = c->time_offset;
    return 1;
}

int32_t tg_conn_time_offset(tg_conn *c) { return c->time_offset; }

/* ---------------- wymiana kluczy ---------------- */

static int plain_call(tg_conn *c, const uint8_t *body, size_t n, uint8_t **resp, size_t *rlen, char *err, int errlen)
{
    wbuf w = { 0, 0, 0 };
    uint8_t zero8[8] = { 0 };
    w_put(&w, zero8, 8);
    w_u64(&w, gen_msg_id(c));
    w_u32(&w, (uint32_t)n);
    w_put(&w, body, n);
    int r = frame_send(c, w.p, w.n);
    free(w.p);
    if (r) { set_err(err, errlen, "wysyłanie nie powiodło się"); return -1; }
    uint8_t *f; size_t fn; int32_t code = 0;
    for (;;) {
        r = frame_recv(c, &f, &fn, 20000, &code);
        if (r == 1) continue;
        break;
    }
    if (r == -3) { char m[64]; snprintf(m, sizeof(m), "serwer zwrócił kod %d", (int)code); set_err(err, errlen, m); return -1; }
    if (r == -2) { set_err(err, errlen, "serwer nie odpowiada (timeout)"); return -1; }
    if (r) { set_err(err, errlen, "połączenie przerwane"); return -1; }
    if (fn < 20 || r64(f) != 0) { free(f); set_err(err, errlen, "zła ramka jawna"); return -1; }
    uint32_t dl = r32(f + 16);
    if ((size_t)dl + 20 > fn) { free(f); set_err(err, errlen, "zła długość ramki jawnej"); return -1; }
    *resp = (uint8_t *)malloc(dl ? dl : 1);
    memcpy(*resp, f + 20, dl);
    *rlen = dl;
    free(f);
    return 0;
}

static void rsa_encrypt_block(const uint8_t n[256], const uint8_t data[256], uint8_t out[256])
{
    tg_bn m, nn, r;
    static const uint8_t e[3] = { 0x01, 0x00, 0x01 };
    bn_from_be(&m, data, 256);
    bn_from_be(&nn, n, 256);
    bn_modexp(&r, &m, e, 3, &nn);
    bn_to_be(&r, out, 256);
}

static int64_t rsa_fingerprint(const uint8_t n[256])
{
    wbuf w = { 0, 0, 0 };
    static const uint8_t e[3] = { 0x01, 0x00, 0x01 };
    w_bytes(&w, n, 256);        /* moduł: 256 B z bitem 1 na początku, więc bez zer wiodących */
    w_bytes(&w, e, 3);
    uint8_t h[20];
    tg_sha1(w.p, w.n, h);
    free(w.p);
    return (int64_t)r64(h + 12);
}

static void tmp_key_iv(const uint8_t sn[16], const uint8_t nn[32], uint8_t key[32], uint8_t iv[32])
{
    uint8_t a[48], b[48], c2[64], h1[20], h2[20], h3[20];
    memcpy(a, nn, 32); memcpy(a + 32, sn, 16);       /* new_nonce + server_nonce */
    memcpy(b, sn, 16); memcpy(b + 16, nn, 32);       /* server_nonce + new_nonce */
    memcpy(c2, nn, 32); memcpy(c2 + 32, nn, 32);     /* new_nonce + new_nonce */
    tg_sha1(a, 48, h1); tg_sha1(b, 48, h2); tg_sha1(c2, 64, h3);
    memcpy(key, h1, 20); memcpy(key + 20, h2, 12);
    memcpy(iv, h2 + 12, 8); memcpy(iv + 8, h3, 20); memcpy(iv + 28, nn, 4);
}

int tg_conn_handshake(tg_conn *c, char *err, int errlen)
{
    uint8_t nonce[16], server_nonce[16], new_nonce[32];
    uint8_t *resp = NULL; size_t rl = 0;
    wbuf w = { 0, 0, 0 };
    int ret = -1;
    uint8_t *tmp = NULL;

    tg_random(nonce, 16);
    w_u32(&w, 0xbe7e8ef1u); w_put(&w, nonce, 16);
    if (plain_call(c, w.p, w.n, &resp, &rl, err, errlen)) { free(w.p); return -1; }
    free(w.p); w.p = NULL; w.n = w.cap = 0;

    /* resPQ */
    if (rl < 4 + 32 || r32(resp) != 0x05162463u || memcmp(resp + 4, nonce, 16) != 0) { set_err(err, errlen, "zła odpowiedź resPQ"); goto done; }
    memcpy(server_nonce, resp + 20, 16);
    const uint8_t *pqb; size_t pql;
    size_t off = 36;
    size_t used = r_bytes(resp + off, rl - off, &pqb, &pql);
    if (!used || pql == 0 || pql > 8) { set_err(err, errlen, "zły pq"); goto done; }
    off += used;
    if (off + 8 > rl || r32(resp + off) != ID_VECTOR) { set_err(err, errlen, "brak listy odcisków kluczy"); goto done; }
    uint32_t nfp = r32(resp + off + 4);
    off += 8;
    if (nfp > 16 || off + (size_t)nfp * 8 > rl) { set_err(err, errlen, "zła lista odcisków"); goto done; }
    uint64_t pq = 0;
    for (size_t i = 0; i < pql; i++) pq = (pq << 8) | pqb[i];
    uint32_t p, q;
    if (!tg_factor_pq(pq, &p, &q)) { set_err(err, errlen, "nie udało się rozłożyć pq"); goto done; }

    /* wybór klucza RSA: najpierw nowe, potem stare */
    const uint8_t *rsa_n = NULL; int64_t fp_use = 0;
    for (int pass = 0; pass < 2 && !rsa_n; pass++) {
        for (uint32_t i = 0; i < nfp && !rsa_n; i++) {
            int64_t fp = (int64_t)r64(resp + off + i * 8);
            for (int k = 0; k < TG_NKEYS; k++) {
                if (kRsaKeys[k].fp == fp && kRsaKeys[k].old == pass) { rsa_n = kRsaKeys[k].n; fp_use = fp; break; }
            }
            if (!rsa_n && gHaveExtraKey && rsa_fingerprint(gExtraKey) == fp) { rsa_n = gExtraKey; fp_use = fp; }
        }
    }
    if (!rsa_n) { set_err(err, errlen, "serwer używa nieznanego klucza RSA"); goto done; }

    tg_random(new_nonce, 32);
    uint8_t pb[4], qb[4];
    pb[0] = (uint8_t)(p >> 24); pb[1] = (uint8_t)(p >> 16); pb[2] = (uint8_t)(p >> 8); pb[3] = (uint8_t)p;
    qb[0] = (uint8_t)(q >> 24); qb[1] = (uint8_t)(q >> 16); qb[2] = (uint8_t)(q >> 8); qb[3] = (uint8_t)q;
    wbuf inner = { 0, 0, 0 };
    w_u32(&inner, 0x83c95aecu);
    w_bytes(&inner, pqb, pql);
    w_bytes(&inner, pb, 4); w_bytes(&inner, qb, 4);
    w_put(&inner, nonce, 16); w_put(&inner, server_nonce, 16); w_put(&inner, new_nonce, 32);
    uint8_t block[256];
    memset(block, 0, 256);
    tg_sha1(inner.p, inner.n, block + 1);
    memcpy(block + 21, inner.p, inner.n);
    tg_random(block + 21 + inner.n, 235 - inner.n);
    free(inner.p);
    uint8_t enc[256];
    rsa_encrypt_block(rsa_n, block, enc);
    free(resp); resp = NULL;

    w_u32(&w, 0xd712e4beu); w_put(&w, nonce, 16); w_put(&w, server_nonce, 16);
    w_bytes(&w, pb, 4); w_bytes(&w, qb, 4);
    w_u64(&w, (uint64_t)fp_use);
    w_bytes(&w, enc, 256);
    if (plain_call(c, w.p, w.n, &resp, &rl, err, errlen)) { free(w.p); return -1; }
    free(w.p); w.p = NULL; w.n = w.cap = 0;

    if (rl < 36 || memcmp(resp + 4, nonce, 16) != 0 || memcmp(resp + 20, server_nonce, 16) != 0) { set_err(err, errlen, "zły nonce w server_DH_params"); goto done; }
    if (r32(resp) != 0xd0e8075cu) { set_err(err, errlen, r32(resp) == 0x79cb045du ? "serwer odrzucił parametry DH (fail)" : "nieoczekiwana odpowiedź DH"); goto done; }
    const uint8_t *ea; size_t eal;
    if (!r_bytes(resp + 36, rl - 36, &ea, &eal) || (eal & 15) || eal < 32) { set_err(err, errlen, "zła zaszyfrowana odpowiedź"); goto done; }

    uint8_t key[32], iv[32];
    tmp_key_iv(server_nonce, new_nonce, key, iv);
    tmp = (uint8_t *)malloc(eal);
    tg_aes_ige_decrypt(key, iv, ea, tmp, eal);
    /* hash(20) + server_DH_inner_data */
    const uint8_t *d = tmp + 20;
    size_t dn = eal - 20;
    if (dn < 4 + 32 + 4 || r32(d) != 0xb5890dbau || memcmp(d + 4, nonce, 16) != 0 || memcmp(d + 20, server_nonce, 16) != 0) { set_err(err, errlen, "zła treść server_DH_inner_data"); goto done; }
    int32_t g = (int32_t)r32(d + 36);
    size_t o2 = 40;
    const uint8_t *dhp, *ga; size_t dhpl, gal;
    size_t u1 = r_bytes(d + o2, dn - o2, &dhp, &dhpl);
    if (!u1) { set_err(err, errlen, "zły dh_prime"); goto done; }
    o2 += u1;
    size_t u2 = r_bytes(d + o2, dn - o2, &ga, &gal);
    if (!u2) { set_err(err, errlen, "zły g_a"); goto done; }
    o2 += u2;
    if (o2 + 4 > dn) { set_err(err, errlen, "brak server_time"); goto done; }
    int32_t server_time = (int32_t)r32(d + o2);
    o2 += 4;
    uint8_t hh[20];
    tg_sha1(d, o2, hh);
    if (memcmp(hh, tmp, 20) != 0) { set_err(err, errlen, "zła suma kontrolna server_DH_inner_data"); goto done; }
    if (dhpl != 256 || gal == 0 || gal > 256 || g < 2 || g > 7) { set_err(err, errlen, "dziwne parametry DH"); goto done; }

    tg_bn P, G, GA, B2, GB, AK, one, pm1, lo, hi, t;
    bn_from_be(&P, dhp, 256);
    bn_set_u32(&G, (uint32_t)g);
    bn_from_be(&GA, ga, gal);
    bn_set_u32(&one, 1);
    bn_sub(&pm1, &P, &one);
    uint8_t bexp[256];
    tg_random(bexp, 256);
    bn_from_be(&B2, bexp, 256);
    (void)B2;
    if (!bn_modexp(&GB, &G, bexp, 256, &P) || !bn_modexp(&AK, &GA, bexp, 256, &P)) { set_err(err, errlen, "bn_modexp"); goto done; }
    /* zakresy bezpieczeństwa */
    bn_zero(&lo);
    lo.w[1984 >> 5] = 1u << (1984 & 31); lo.n = (1984 >> 5) + 1;       /* 2^1984 */
    bn_sub(&hi, &P, &lo);
    if (!(bn_cmp(&G, &one) > 0 && bn_cmp(&G, &pm1) < 0) ||
        !(bn_cmp(&GA, &lo) >= 0 && bn_cmp(&GA, &hi) <= 0) ||
        !(bn_cmp(&GB, &lo) >= 0 && bn_cmp(&GB, &hi) <= 0)) { set_err(err, errlen, "parametry DH poza bezpiecznym zakresem"); goto done; }
    (void)t;

    uint8_t gb_full[256], gbb[256]; size_t gblen = 256;
    bn_to_be(&GB, gb_full, 256);
    size_t skip = 0;
    while (skip < 255 && gb_full[skip] == 0) skip++;
    memcpy(gbb, gb_full + skip, 256 - skip);
    gblen = 256 - skip;
    uint8_t auth_key[256];
    bn_to_be(&AK, auth_key, 256);

    wbuf cin = { 0, 0, 0 };
    w_u32(&cin, 0x6643b654u); w_put(&cin, nonce, 16); w_put(&cin, server_nonce, 16); w_u64(&cin, 0); w_bytes(&cin, gbb, gblen);
    size_t total = 20 + cin.n;
    size_t padded = (total + 15) & ~(size_t)15;
    uint8_t *pl = (uint8_t *)calloc(padded, 1);
    tg_sha1(cin.p, cin.n, pl);
    memcpy(pl + 20, cin.p, cin.n);
    if (padded > total) tg_random(pl + total, padded - total);
    free(cin.p);
    uint8_t *encc = (uint8_t *)malloc(padded);
    tg_aes_ige_encrypt(key, iv, pl, encc, padded);
    free(pl);
    free(resp); resp = NULL;

    w_u32(&w, 0xf5045f1fu); w_put(&w, nonce, 16); w_put(&w, server_nonce, 16); w_bytes(&w, encc, padded);
    free(encc);
    if (plain_call(c, w.p, w.n, &resp, &rl, err, errlen)) { free(w.p); free(tmp); return -1; }
    free(w.p); w.p = NULL; w.n = w.cap = 0;
    if (rl < 36 + 16 || memcmp(resp + 4, nonce, 16) != 0 || memcmp(resp + 20, server_nonce, 16) != 0) { set_err(err, errlen, "zły nonce w dh_gen"); goto done; }
    uint32_t gid = r32(resp);
    int which = gid == 0x3bcbf734u ? 1 : gid == 0x46dc1fb9u ? 2 : gid == 0xa69dae02u ? 3 : 0;
    if (!which) { set_err(err, errlen, "nieznana odpowiedź dh_gen"); goto done; }
    uint8_t akh[20], nh[20], nbuf[32 + 1 + 8];
    tg_sha1(auth_key, 256, akh);
    memcpy(nbuf, new_nonce, 32); nbuf[32] = (uint8_t)which; memcpy(nbuf + 33, akh, 8);
    tg_sha1(nbuf, 41, nh);
    if (memcmp(nh + 4, resp + 36, 16) != 0) { set_err(err, errlen, "zły new_nonce_hash"); goto done; }
    if (which != 1) { set_err(err, errlen, which == 2 ? "serwer prosi o ponowienie wymiany kluczy" : "wymiana kluczy odrzucona"); goto done; }

    uint64_t salt = r64(new_nonce) ^ r64(server_nonce);
    int32_t off_t = (int32_t)((int64_t)server_time - (int64_t)now_sec());
    tg_conn_set_auth(c, auth_key, salt, off_t);
    ret = 0;
done:
    free(resp);
    free(tmp);
    return ret;
}

/* ---------------- sesja szyfrowana (MTProto 2.0) ---------------- */

static void derive(const uint8_t *auth_key, const uint8_t msg_key[16], int x, uint8_t key[32], uint8_t iv[32])
{
    uint8_t buf[52], a[32], b[32];
    memcpy(buf, msg_key, 16); memcpy(buf + 16, auth_key + x, 36);
    tg_sha256(buf, 52, a);
    memcpy(buf, auth_key + 40 + x, 36); memcpy(buf + 36, msg_key, 16);
    tg_sha256(buf, 52, b);
    memcpy(key, a, 8); memcpy(key + 8, b + 8, 16); memcpy(key + 24, a + 24, 8);
    memcpy(iv, b, 8); memcpy(iv + 8, a + 8, 16); memcpy(iv + 24, b + 24, 8);
}

/* wysyła treść jako wiadomość szyfrowaną; wołać pod blokadą (poza handshake). */
static int send_enc(tg_conn *c, const uint8_t *body, size_t blen, int content, uint64_t *out_mid)
{
    if (!c->have_key || c->fd < 0) return -1;
    uint64_t mid = gen_msg_id(c);
    uint32_t seqno = c->seq * 2 + (content ? 1u : 0u);
    if (content) c->seq++;
    size_t base = 32 + blen;
    uint8_t rb;
    tg_random(&rb, 1);
    size_t pad = 12 + ((16 - ((base + 12) & 15)) & 15) + 16 * (size_t)(rb & 3);
    size_t total = base + pad;
    uint8_t *pt = (uint8_t *)malloc(total);
    if (!pt) return -1;
    put64(pt, c->salt); put64(pt + 8, c->session_id); put64(pt + 16, mid); put32(pt + 24, seqno); put32(pt + 28, (uint32_t)blen);
    memcpy(pt + 32, body, blen);
    tg_random(pt + base, pad);
    uint8_t *tmp = (uint8_t *)malloc(32 + total);
    memcpy(tmp, c->auth_key + 88, 32);
    memcpy(tmp + 32, pt, total);
    uint8_t large[32], mk[16];
    tg_sha256(tmp, 32 + total, large);
    free(tmp);
    memcpy(mk, large + 8, 16);
    uint8_t key[32], iv[32];
    derive(c->auth_key, mk, 0, key, iv);
    uint8_t *pkt = (uint8_t *)malloc(24 + total);
    memcpy(pkt, c->auth_key_id, 8);
    memcpy(pkt + 8, mk, 16);
    tg_aes_ige_encrypt(key, iv, pt, pkt + 24, total);
    free(pt);
    int r = frame_send(c, pkt, 24 + total);
    free(pkt);
    if (out_mid) *out_mid = mid;
    return r;
}

static void flush_acks_locked(tg_conn *c)
{
    if (!c->nacks) return;
    wbuf w = { 0, 0, 0 };
    w_u32(&w, ID_ACK); w_u32(&w, ID_VECTOR); w_u32(&w, (uint32_t)c->nacks);
    for (int i = 0; i < c->nacks; i++) w_u64(&w, c->acks[i]);
    c->nacks = 0;
    send_enc(c, w.p, w.n, 0, NULL);
    free(w.p);
}

uint32_t tg_conn_request(tg_conn *c, const uint8_t *tl, size_t len)
{
    pthread_mutex_lock(&c->lock);
    if (c->closed || !c->have_key) { pthread_mutex_unlock(&c->lock); return 0; }
    if (c->npend == c->cap) {
        int nc = c->cap ? c->cap * 2 : 16;
        c->pend = (pending_t *)realloc(c->pend, (size_t)nc * sizeof(pending_t));
        c->cap = nc;
    }
    pending_t *p = &c->pend[c->npend];
    p->token = c->next_token++;
    p->data = (uint8_t *)malloc(len ? len : 1);
    memcpy(p->data, tl, len);
    p->len = len;
    uint64_t mid = 0;
    int r = send_enc(c, tl, len, 1, &mid);
    if (r) { free(p->data); pthread_mutex_unlock(&c->lock); return 0; }
    p->msg_id = mid;
    c->npend++;
    uint32_t tok = p->token;
    pthread_mutex_unlock(&c->lock);
    return tok;
}

/* usuwa zapytanie o danym msg_id, zwraca token albo 0 */
static uint32_t pending_take(tg_conn *c, uint64_t mid)
{
    uint32_t tok = 0;
    pthread_mutex_lock(&c->lock);
    for (int i = 0; i < c->npend; i++) {
        if (c->pend[i].msg_id == mid) {
            tok = c->pend[i].token;
            free(c->pend[i].data);
            c->pend[i] = c->pend[c->npend - 1];
            c->npend--;
            break;
        }
    }
    pthread_mutex_unlock(&c->lock);
    return tok;
}

static void pending_resend(tg_conn *c, uint64_t mid)
{
    pthread_mutex_lock(&c->lock);
    for (int i = 0; i < c->npend; i++) {
        if (c->pend[i].msg_id == mid) {
            uint64_t nm = 0;
            if (send_enc(c, c->pend[i].data, c->pend[i].len, 1, &nm) == 0) c->pend[i].msg_id = nm;
            break;
        }
    }
    pthread_mutex_unlock(&c->lock);
}

static void deliver_rpc(tg_conn *c, uint64_t req_id, const uint8_t *res, size_t n);

static void handle_message(tg_conn *c, uint64_t msg_id, uint32_t seqno, const uint8_t *b, size_t n, int depth)
{
    if (n < 4 || depth > 8) return;
    uint32_t id = r32(b);
    if (id == ID_CONTAINER) {
        if (n < 8) return;
        uint32_t cnt = r32(b + 4);
        size_t off = 8;
        for (uint32_t i = 0; i < cnt; i++) {
            if (off + 16 > n) break;
            uint64_t mid = r64(b + off);
            uint32_t sq = r32(b + off + 8);
            uint32_t bl = r32(b + off + 12);
            off += 16;
            if (off + bl > n) break;
            handle_message(c, mid, sq, b + off, bl, depth + 1);
            off += bl;
        }
        return;
    }
    if (seqno & 1) {
        pthread_mutex_lock(&c->lock);
        if (c->nacks < 128) c->acks[c->nacks++] = msg_id;
        pthread_mutex_unlock(&c->lock);
    }
    switch (id) {
    case ID_RPC_RESULT:
        if (n >= 12) deliver_rpc(c, r64(b + 4), b + 12, n - 12);
        break;
    case ID_NEW_SESSION:
        if (n >= 28) { pthread_mutex_lock(&c->lock); c->salt = r64(b + 20); pthread_mutex_unlock(&c->lock); }
        break;
    case ID_BAD_SALT:
        if (n >= 28) {
            pthread_mutex_lock(&c->lock); c->salt = r64(b + 20); pthread_mutex_unlock(&c->lock);
            pending_resend(c, r64(b + 4));
        }
        break;
    case ID_BAD_MSG:
        if (n >= 20) {
            uint64_t bad = r64(b + 4);
            int code = (int)r32(b + 16);
            if (code == 16 || code == 17) {
                pthread_mutex_lock(&c->lock);
                c->time_offset = (int32_t)((int64_t)(msg_id >> 32) - (int64_t)now_sec());
                c->last_msg_id = 0;
                pthread_mutex_unlock(&c->lock);
                pending_resend(c, bad);
            } else if (code == 32 || code == 33) {
                pending_resend(c, bad);
            } else {
                uint32_t tok = pending_take(c, bad);
                if (tok && c->ev.on_error) c->ev.on_error(c->ev.ud, tok, -code, "bad_msg_notification");
            }
        }
        break;
    case ID_ACK: case ID_PONG:
        break;
    case ID_GZIP: {
        const uint8_t *pd; size_t pl;
        if (n >= 8 && r_bytes(b + 4, n - 4, &pd, &pl)) {
            uint8_t *out; size_t ol;
            if (tg_gunzip(pd, pl, &out, &ol) == 0) {
                handle_message(c, msg_id, 0, out, ol, depth + 1);
                free(out);
            }
        }
        break;
    }
    case 0x276d3ec6u: case 0x809db6dfu: case 0x04deb57du: case 0x8cc0d131u: case 0xae500895u: case 0x0949d9dcu:
        break;                                              /* informacje serwisowe: ignorujemy */
    default:
        if (c->ev.on_update) c->ev.on_update(c->ev.ud, b, n);
        break;
    }
}

static void deliver_rpc(tg_conn *c, uint64_t req_id, const uint8_t *res, size_t n)
{
    uint8_t *unz = NULL;
    if (n >= 4 && r32(res) == ID_GZIP) {
        const uint8_t *pd; size_t pl;
        if (n >= 8 && r_bytes(res + 4, n - 4, &pd, &pl)) {
            size_t ol;
            if (tg_gunzip(pd, pl, &unz, &ol) == 0) { res = unz; n = ol; }
        }
    }
    uint32_t tok = pending_take(c, req_id);
    if (tok) {
        if (n >= 8 && r32(res) == ID_RPC_ERROR) {
            int code = (int)r32(res + 4);
            const uint8_t *m; size_t ml;
            char msg[160];
            msg[0] = 0;
            if (r_bytes(res + 8, n - 8, &m, &ml)) {
                if (ml > sizeof(msg) - 1) ml = sizeof(msg) - 1;
                memcpy(msg, m, ml); msg[ml] = 0;
            }
            if (c->ev.on_error) c->ev.on_error(c->ev.ud, tok, code, msg);
        } else if (c->ev.on_result) {
            c->ev.on_result(c->ev.ud, tok, res, n);
        }
    }
    free(unz);
}

static void fail_all_pending(tg_conn *c, const char *why)
{
    for (;;) {
        uint32_t tok = 0;
        pthread_mutex_lock(&c->lock);
        if (c->npend > 0) {
            tok = c->pend[c->npend - 1].token;
            free(c->pend[c->npend - 1].data);
            c->npend--;
        }
        pthread_mutex_unlock(&c->lock);
        if (!tok) break;
        if (c->ev.on_error) c->ev.on_error(c->ev.ud, tok, -1, why);
    }
}

static void send_ping(tg_conn *c)
{
    wbuf w = { 0, 0, 0 };
    uint8_t r[8];
    tg_random(r, 8);
    w_u32(&w, ID_PING); w_put(&w, r, 8); w_u32(&w, 75);
    pthread_mutex_lock(&c->lock);
    send_enc(c, w.p, w.n, 0, NULL);
    pthread_mutex_unlock(&c->lock);
    free(w.p);
}

static int process_packet(tg_conn *c, const uint8_t *f, size_t fn)
{
    if (fn < 24 + 16 + 32 || ((fn - 24) & 15)) return -1;
    if (memcmp(f, c->auth_key_id, 8) != 0) return -1;
    size_t el = fn - 24;
    uint8_t key[32], iv[32];
    derive(c->auth_key, f + 8, 8, key, iv);
    uint8_t *pt = (uint8_t *)malloc(el);
    tg_aes_ige_decrypt(key, iv, f + 24, pt, el);
    uint8_t *tmp = (uint8_t *)malloc(32 + el);
    memcpy(tmp, c->auth_key + 88 + 8, 32);
    memcpy(tmp + 32, pt, el);
    uint8_t large[32];
    tg_sha256(tmp, 32 + el, large);
    free(tmp);
    if (memcmp(large + 8, f + 8, 16) != 0) { free(pt); return -1; }
    uint64_t sess = r64(pt + 8);
    uint64_t mid = r64(pt + 16);
    uint32_t seqno = r32(pt + 24);
    uint32_t blen = r32(pt + 28);
    if (sess != c->session_id || (size_t)blen + 32 > el || blen < 4) { free(pt); return -1; }
    handle_message(c, mid, seqno, pt + 32, blen, 0);
    free(pt);
    pthread_mutex_lock(&c->lock);
    flush_acks_locked(c);
    pthread_mutex_unlock(&c->lock);
    return 0;
}

void tg_conn_run(tg_conn *c)
{
    const char *reason = "połączenie zamknięte";
    while (!c->closed) {
        int w = io_wait(c->fd, 1000);
        if (w < 0) { reason = "błąd gniazda"; break; }
        if (w == 0) {
            long t = now_sec();
            if (t - c->last_rx > 150) { reason = "serwer przestał odpowiadać"; break; }
            if (t - c->last_ping >= 30) { c->last_ping = t; send_ping(c); }
            continue;
        }
        uint8_t *f = NULL; size_t fn = 0; int32_t code = 0;
        int r = frame_recv(c, &f, &fn, 30000, &code);
        if (r == 1) { c->last_rx = now_sec(); continue; }
        if (r == -3) { snprintf(c->close_reason, sizeof(c->close_reason), "serwer zwrócił błąd transportu %d", (int)code); reason = c->close_reason; break; }
        if (r) { reason = r == -2 ? "przerwa w odbiorze" : "połączenie przerwane przez serwer"; break; }
        c->last_rx = now_sec();
        int pr = process_packet(c, f, fn);
        free(f);
        if (pr) { reason = "uszkodzony pakiet z serwera"; break; }
    }
    c->closed = 1;
    if (c->fd >= 0) shutdown(c->fd, SHUT_RDWR);
    fail_all_pending(c, reason);
    if (c->ev.on_closed) c->ev.on_closed(c->ev.ud, reason);
}

/* ---------------- SRP (hasło dwuskładnikowe) ---------------- */

static void sha256_cat(uint8_t out[32], const uint8_t *a, size_t al, const uint8_t *b, size_t bl, const uint8_t *c3, size_t cl)
{
    tg_sha256_ctx s;
    tg_sha256_init(&s);
    if (a) tg_sha256_update(&s, a, al);
    if (b) tg_sha256_update(&s, b, bl);
    if (c3) tg_sha256_update(&s, c3, cl);
    tg_sha256_final(&s, out);
}

int tg_srp_check(const uint8_t *salt1, size_t salt1_len, const uint8_t *salt2, size_t salt2_len,
                 int32_t g, const uint8_t p[256], const uint8_t srp_b[256], size_t srp_b_len,
                 const uint8_t *password, size_t password_len, const uint8_t rnd256[256],
                 uint8_t out_a[256], uint8_t out_m1[32])
{
    if (memcmp(p, kDhGoodPrime, 256) != 0 || g < 3 || g > 7 || g == 6 || srp_b_len > 256 || srp_b_len == 0) return -1;
    /* x = PH2 */
    uint8_t h1[32], h2[32], h3[64], x[32];
    sha256_cat(h1, salt1, salt1_len, password, password_len, salt1, salt1_len);
    sha256_cat(h2, salt2, salt2_len, h1, 32, salt2, salt2_len);
    tg_pbkdf2_sha512(h2, 32, salt1, salt1_len, 100000, h3);
    sha256_cat(x, salt2, salt2_len, h3, 64, salt2, salt2_len);

    uint8_t pfh[256], gfh[256], bfh[256], afh[256];
    memcpy(pfh, p, 256);
    memset(gfh, 0, 256); gfh[255] = (uint8_t)g;
    memset(bfh, 0, 256); memcpy(bfh + 256 - srp_b_len, srp_b, srp_b_len);

    tg_bn P, G, B, X, gx, k, kgx, A, a, gb, t, u, ux, aux, S;
    bn_from_be(&P, p, 256);
    bn_set_u32(&G, (uint32_t)g);
    bn_from_be(&B, bfh, 256);
    bn_from_be(&X, x, 32);
    if (bn_cmp(&B, &P) >= 0 || B.n == 0) return -2;
    uint8_t ebytes[256];
    memcpy(ebytes, rnd256, 256);
    if (!bn_modexp(&A, &G, ebytes, 256, &P)) return -3;
    if (bn_cmp(&A, &P) >= 0) return -3;
    bn_to_be(&A, afh, 256);
    uint8_t kb[32], ub[32];
    sha256_cat(kb, pfh, 256, gfh, 256, NULL, 0);
    sha256_cat(ub, afh, 256, bfh, 256, NULL, 0);
    bn_from_be(&k, kb, 32);
    bn_from_be(&u, ub, 32);
    uint8_t xb[32]; memcpy(xb, x, 32);
    if (!bn_modexp(&gx, &G, xb, 32, &P)) return -4;
    if (!bn_modmul(&kgx, &k, &gx, &P)) return -4;
    /* gb = (B - k*g^x) mod p */
    if (bn_cmp(&B, &kgx) >= 0) bn_sub(&gb, &B, &kgx);
    else { bn_sub(&t, &kgx, &B); bn_sub(&gb, &P, &t); }
    /* exponent = a + u*x */
    bn_from_be(&a, rnd256, 256);
    bn_mul(&ux, &u, &X);
    bn_add(&aux, &a, &ux);
    uint8_t eb[300];
    int need = (bn_bits(&aux) + 7) >> 3;
    if (need > 300) return -5;
    bn_to_be(&aux, eb, (size_t)need);
    if (!bn_modexp(&S, &gb, eb, (size_t)need, &P)) return -5;
    uint8_t sfh[256], K[32];
    bn_to_be(&S, sfh, 256);
    tg_sha256(sfh, 256, K);
    uint8_t hp[32], hg[32], hx[32], hs1[32], hs2[32];
    tg_sha256(pfh, 256, hp);
    tg_sha256(gfh, 256, hg);
    for (int i = 0; i < 32; i++) hx[i] = (uint8_t)(hp[i] ^ hg[i]);
    tg_sha256(salt1, salt1_len, hs1);
    tg_sha256(salt2, salt2_len, hs2);
    tg_sha256_ctx m;
    tg_sha256_init(&m);
    tg_sha256_update(&m, hx, 32); tg_sha256_update(&m, hs1, 32); tg_sha256_update(&m, hs2, 32);
    tg_sha256_update(&m, afh, 256); tg_sha256_update(&m, bfh, 256); tg_sha256_update(&m, K, 32);
    tg_sha256_final(&m, out_m1);
    memcpy(out_a, afh, 256);
    return 0;
}
