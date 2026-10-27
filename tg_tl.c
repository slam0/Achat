#include "tg_tl.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

enum { TT_INT, TT_LONG, TT_DOUBLE, TT_STRING, TT_BYTES, TT_INT128, TT_INT256, TT_BOOL, TT_TRUE, TT_FLAGS,
       TT_VECTOR, TT_OBJECT, TT_BARE, TT_ANY };

typedef struct tl_type {
    int kind;
    struct tl_type *elem;       /* dla wektora */
    int bare_vec;               /* vector<...> (małą literą): bez nagłówka */
    char *tname;                /* nazwa typu dla TT_OBJECT/TT_BARE */
} tl_type;

typedef struct {
    char *name;
    tl_type *type;
    int flagvar;                /* indeks pola z flagami albo -1 */
    int flagbit;
} tl_param;

typedef struct {
    char *name;
    uint32_t id;
    int nparams;
    tl_param *params;
    char *rtype;
    int is_func;
} tl_con;

typedef struct { uint32_t id; int idx; } id_ent;
typedef struct { const char *name; int idx; } name_ent;

struct tl_schema {
    tl_con *cons;
    int ncons, cap;
    id_ent *by_id;
    name_ent *by_name;
    int layer;
};

#define VECTOR_ID 0x1cb5c415u
#define BOOL_TRUE 0x997275b5u
#define BOOL_FALSE 0xbc799737u
#define MAX_DEPTH 48

static char *xdup(const char *s, size_t n)
{
    char *r = (char *)malloc(n + 1);
    if (!r) return NULL;
    memcpy(r, s, n);
    r[n] = 0;
    return r;
}

/* ---------------- parsowanie schematu ---------------- */

static void type_free(tl_type *t)
{
    if (!t) return;
    type_free(t->elem);
    free(t->tname);
    free(t);
}

static tl_type *type_parse(const char *s, size_t n)
{
    tl_type *t = (tl_type *)calloc(1, sizeof(tl_type));
    if (!t) return NULL;
    #define IS(lit) (n == sizeof(lit) - 1 && memcmp(s, lit, n) == 0)
    if (IS("int")) t->kind = TT_INT;
    else if (IS("long")) t->kind = TT_LONG;
    else if (IS("double")) t->kind = TT_DOUBLE;
    else if (IS("string")) t->kind = TT_STRING;
    else if (IS("bytes")) t->kind = TT_BYTES;
    else if (IS("int128")) t->kind = TT_INT128;
    else if (IS("int256")) t->kind = TT_INT256;
    else if (IS("Bool")) t->kind = TT_BOOL;
    else if (IS("true")) t->kind = TT_TRUE;
    else if (IS("#")) t->kind = TT_FLAGS;
    else if (n > 7 && (memcmp(s, "Vector<", 7) == 0 || memcmp(s, "vector<", 7) == 0) && s[n - 1] == '>') {
        t->kind = TT_VECTOR;
        t->bare_vec = s[0] == 'v';
        t->elem = type_parse(s + 7, n - 8);
        if (!t->elem) { free(t); return NULL; }
    } else if (n > 1 && s[0] == '!') {
        t->kind = TT_ANY;
    } else if (n > 1 && s[0] == '%') {
        t->kind = TT_BARE;
        t->tname = xdup(s + 1, n - 1);
    } else {
        t->kind = TT_OBJECT;
        t->tname = xdup(s, n);
        if (n == 1 && s[0] == 'X') t->kind = TT_ANY;
    }
    #undef IS
    return t;
}

static int cmp_id(const void *a, const void *b)
{
    uint32_t x = ((const id_ent *)a)->id, y = ((const id_ent *)b)->id;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static int cmp_name(const void *a, const void *b)
{
    return strcmp(((const name_ent *)a)->name, ((const name_ent *)b)->name);
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int add_con(tl_schema *s, tl_con *c)
{
    if (s->ncons == s->cap) {
        int ncap = s->cap ? s->cap * 2 : 512;
        tl_con *n = (tl_con *)realloc(s->cons, (size_t)ncap * sizeof(tl_con));
        if (!n) return 0;
        s->cons = n;
        s->cap = ncap;
    }
    s->cons[s->ncons++] = *c;
    return 1;
}

static void parse_line(tl_schema *s, const char *ln, size_t n, int is_func)
{
    /* nazwa#id parametry = Typ; */
    size_t i = 0;
    while (i < n && ln[i] == ' ') i++;
    size_t ns = i;
    while (i < n && ln[i] != '#' && ln[i] != ' ') i++;
    if (i >= n || ln[i] != '#') return;
    size_t ne = i;
    i++;
    uint32_t id = 0;
    int digits = 0;
    while (i < n && hexval(ln[i]) >= 0) { id = (id << 4) | (uint32_t)hexval(ln[i]); i++; digits++; }
    if (digits == 0) return;
    if (ne - ns == 6 && memcmp(ln + ns, "vector", 6) == 0) return;     /* wektor obsługujemy wbudowanie */
    tl_con c;
    memset(&c, 0, sizeof(c));
    c.name = xdup(ln + ns, ne - ns);
    c.id = id;
    c.is_func = is_func;
    int cap = 8;
    c.params = (tl_param *)calloc((size_t)cap, sizeof(tl_param));
    /* parametry do " = " */
    while (i < n) {
        while (i < n && ln[i] == ' ') i++;
        if (i >= n) break;
        if (ln[i] == '=') { i++; break; }
        size_t ts = i;
        while (i < n && ln[i] != ' ') i++;
        size_t te = i;
        if (ln[ts] == '{') continue;                                    /* {X:Type} */
        const char *tok = ln + ts;
        size_t tl = te - ts;
        const char *colon = (const char *)memchr(tok, ':', tl);
        if (!colon) continue;
        if (c.nparams == cap) { cap *= 2; c.params = (tl_param *)realloc(c.params, (size_t)cap * sizeof(tl_param)); }
        tl_param *p = &c.params[c.nparams];
        memset(p, 0, sizeof(*p));
        p->name = xdup(tok, (size_t)(colon - tok));
        p->flagvar = -1;
        const char *ty = colon + 1;
        size_t tyl = tl - (size_t)(ty - tok);
        /* flagi: flags.N?Typ */
        const char *q = (const char *)memchr(ty, '?', tyl);
        if (q && memchr(ty, '.', (size_t)(q - ty))) {
            const char *dot = (const char *)memchr(ty, '.', (size_t)(q - ty));
            size_t fl = (size_t)(dot - ty);
            int bit = 0;
            for (const char *d = dot + 1; d < q; d++) bit = bit * 10 + (*d - '0');
            for (int k = 0; k < c.nparams; k++) {
                if (strlen(c.params[k].name) == fl && memcmp(c.params[k].name, ty, fl) == 0) { p->flagvar = k; break; }
            }
            p->flagbit = bit;
            p->type = type_parse(q + 1, tyl - (size_t)(q + 1 - ty));
        } else {
            p->type = type_parse(ty, tyl);
        }
        c.nparams++;
    }
    while (i < n && ln[i] == ' ') i++;
    size_t rs = i;
    while (i < n && ln[i] != ';') i++;
    c.rtype = xdup(ln + rs, i - rs);
    add_con(s, &c);
}

tl_schema *tl_schema_load(const char *text, size_t len)
{
    tl_schema *s = (tl_schema *)calloc(1, sizeof(tl_schema));
    if (!s) return NULL;
    int is_func = 0;
    size_t pos = 0;
    while (pos < len) {
        size_t e = pos;
        while (e < len && text[e] != '\n') e++;
        size_t ls = pos, le = e;
        if (le > ls && text[le - 1] == '\r') le--;
        if (le - ls >= 3 && text[ls] == '/' && text[ls + 1] == '/') {
            const char *key = " LAYER ";
            for (size_t k = ls + 2; k + 7 <= le; k++) {
                if (memcmp(text + k, key, 7) == 0) {
                    int v = 0;
                    for (size_t d = k + 7; d < le && text[d] >= '0' && text[d] <= '9'; d++) v = v * 10 + (text[d] - '0');
                    s->layer = v;
                    break;
                }
            }
        } else if (le - ls >= 14 && memcmp(text + ls, "---functions---", 14) == 0) {
            is_func = 1;
        } else if (le - ls >= 11 && memcmp(text + ls, "---types---", 11) == 0) {
            is_func = 0;
        } else if (le > ls) {
            parse_line(s, text + ls, le - ls, is_func);
        }
        pos = e + 1;
    }
    s->by_id = (id_ent *)malloc((size_t)s->ncons * sizeof(id_ent));
    s->by_name = (name_ent *)malloc((size_t)s->ncons * sizeof(name_ent));
    if (!s->by_id || !s->by_name) { tl_schema_free(s); return NULL; }
    for (int i = 0; i < s->ncons; i++) {
        s->by_id[i].id = s->cons[i].id; s->by_id[i].idx = i;
        s->by_name[i].name = s->cons[i].name; s->by_name[i].idx = i;
    }
    qsort(s->by_id, (size_t)s->ncons, sizeof(id_ent), cmp_id);
    qsort(s->by_name, (size_t)s->ncons, sizeof(name_ent), cmp_name);
    return s;
}

void tl_schema_free(tl_schema *s)
{
    if (!s) return;
    for (int i = 0; i < s->ncons; i++) {
        for (int k = 0; k < s->cons[i].nparams; k++) { free(s->cons[i].params[k].name); type_free(s->cons[i].params[k].type); }
        free(s->cons[i].params);
        free(s->cons[i].name);
        free(s->cons[i].rtype);
    }
    free(s->cons);
    free(s->by_id);
    free(s->by_name);
    free(s);
}

int tl_schema_layer(const tl_schema *s) { return s->layer; }
int tl_schema_count(const tl_schema *s) { return s->ncons; }

static const tl_con *find_id(const tl_schema *s, uint32_t id)
{
    int lo = 0, hi = s->ncons - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        uint32_t v = s->by_id[mid].id;
        if (v == id) return &s->cons[s->by_id[mid].idx];
        if (v < id) lo = mid + 1; else hi = mid - 1;
    }
    return NULL;
}

static const tl_con *find_name(const tl_schema *s, const char *name)
{
    int lo = 0, hi = s->ncons - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        int c = strcmp(s->by_name[mid].name, name);
        if (c == 0) return &s->cons[s->by_name[mid].idx];
        if (c < 0) lo = mid + 1; else hi = mid - 1;
    }
    return NULL;
}

uint32_t tl_id_for_name(const tl_schema *s, const char *name)
{
    const tl_con *c = find_name(s, name);
    return c ? c->id : 0;
}

const char *tl_name_for_id(const tl_schema *s, uint32_t id)
{
    const tl_con *c = find_id(s, id);
    return c ? c->name : NULL;
}

static const tl_con *find_first_of_type(const tl_schema *s, const char *tname)
{
    for (int i = 0; i < s->ncons; i++) {
        if (!s->cons[i].is_func && strcmp(s->cons[i].rtype, tname) == 0) return &s->cons[i];
    }
    return NULL;
}

/* ---------------- bufor tekstowy / binarny ---------------- */

typedef struct { char *p; size_t n, cap; int oom; } sbuf;

static void sb_put(sbuf *b, const void *d, size_t n)
{
    if (b->oom) return;
    if (b->n + n + 1 > b->cap) {
        size_t ncap = b->cap ? b->cap : 1024;
        while (ncap < b->n + n + 1) ncap *= 2;
        char *np = (char *)realloc(b->p, ncap);
        if (!np) { b->oom = 1; return; }
        b->p = np; b->cap = ncap;
    }
    memcpy(b->p + b->n, d, n);
    b->n += n;
    b->p[b->n] = 0;
}

static void sb_str(sbuf *b, const char *s) { sb_put(b, s, strlen(s)); }
static void sb_ch(sbuf *b, char c) { sb_put(b, &c, 1); }

static void sb_u32(sbuf *b, uint32_t v)
{
    uint8_t x[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    sb_put(b, x, 4);
}

static void sb_u64(sbuf *b, uint64_t v)
{
    sb_u32(b, (uint32_t)v);
    sb_u32(b, (uint32_t)(v >> 32));
}

/* JSON: napis z poprawną sekwencją UTF-8; zepsute bajty zamieniamy na U+FFFD */
static void json_string(sbuf *b, const uint8_t *s, size_t n)
{
    static const char hex[] = "0123456789abcdef";
    sb_ch(b, '"');
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c == '"') { sb_str(b, "\\\""); i++; }
        else if (c == '\\') { sb_str(b, "\\\\"); i++; }
        else if (c == '\n') { sb_str(b, "\\n"); i++; }
        else if (c == '\r') { sb_str(b, "\\r"); i++; }
        else if (c == '\t') { sb_str(b, "\\t"); i++; }
        else if (c < 0x20) { char u[7] = { '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15], 0 }; sb_str(b, u); i++; }
        else if (c < 0x80) { sb_ch(b, (char)c); i++; }
        else {
            int need = (c & 0xe0) == 0xc0 ? 1 : (c & 0xf0) == 0xe0 ? 2 : (c & 0xf8) == 0xf0 ? 3 : -1;
            int ok = need > 0 && i + (size_t)need < n;
            if (ok) {
                for (int k = 1; k <= need; k++) { if ((s[i + (size_t)k] & 0xc0) != 0x80) { ok = 0; break; } }
            }
            if (ok) {
                uint8_t c1 = s[i + 1];
                if (need == 1 && c < 0xc2) ok = 0;
                else if (need == 2 && ((c == 0xe0 && c1 < 0xa0) || (c == 0xed && c1 >= 0xa0))) ok = 0;
                else if (need == 3 && (c > 0xf4 || (c == 0xf0 && c1 < 0x90) || (c == 0xf4 && c1 >= 0x90))) ok = 0;
            }
            if (ok) { sb_put(b, s + i, (size_t)need + 1); i += (size_t)need + 1; }
            else { sb_str(b, "\xef\xbf\xbd"); i++; }
        }
    }
    sb_ch(b, '"');
}

static void json_hex(sbuf *b, const uint8_t *d, size_t n)
{
    static const char hex[] = "0123456789abcdef";
    sb_ch(b, '"');
    for (size_t i = 0; i < n; i++) { sb_ch(b, hex[d[i] >> 4]); sb_ch(b, hex[d[i] & 15]); }
    sb_ch(b, '"');
}

/* ---------------- odczyt TL -> JSON ---------------- */

typedef struct {
    const tl_schema *s;
    const uint8_t *d;
    size_t len, pos;
    sbuf out;
    char err[160];
} rd;

static int rd_fail(rd *r, const char *what, uint32_t id)
{
    if (!r->err[0]) snprintf(r->err, sizeof(r->err), "%s %08x przy pozycji %lu", what, (unsigned)id, (unsigned long)r->pos);
    return 0;
}

static int rd_u32(rd *r, uint32_t *v)
{
    if (r->pos + 4 > r->len) return rd_fail(r, "koniec danych", 0);
    const uint8_t *p = r->d + r->pos;
    *v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    r->pos += 4;
    return 1;
}

static int rd_u64(rd *r, uint64_t *v)
{
    uint32_t lo, hi;
    if (!rd_u32(r, &lo) || !rd_u32(r, &hi)) return 0;
    *v = (uint64_t)lo | ((uint64_t)hi << 32);
    return 1;
}

static int rd_bytes_field(rd *r, const uint8_t **p, size_t *n)
{
    if (r->pos + 1 > r->len) return rd_fail(r, "koniec danych", 0);
    size_t len = r->d[r->pos];
    size_t hdr = 1;
    if (len == 254) {
        if (r->pos + 4 > r->len) return rd_fail(r, "koniec danych", 0);
        len = (size_t)r->d[r->pos + 1] | ((size_t)r->d[r->pos + 2] << 8) | ((size_t)r->d[r->pos + 3] << 16);
        hdr = 4;
    } else if (len == 255) {
        return rd_fail(r, "zła długość napisu", 255);
    }
    size_t total = (hdr + len + 3) & ~(size_t)3;
    if (r->pos + total > r->len) return rd_fail(r, "napis dłuższy niż dane", (uint32_t)len);
    *p = r->d + r->pos + hdr;
    *n = len;
    r->pos += total;
    return 1;
}

static int rd_object(rd *r, uint32_t id, int have_id, int depth);

static int rd_value(rd *r, const tl_type *t, int depth)
{
    char tmp[48];
    switch (t->kind) {
    case TT_INT: { uint32_t v; if (!rd_u32(r, &v)) return 0; snprintf(tmp, sizeof(tmp), "%d", (int)v); sb_str(&r->out, tmp); return 1; }
    case TT_LONG: {
        uint64_t v;
        if (!rd_u64(r, &v)) return 0;
        long long sv = (long long)(int64_t)v;
        /* liczby spoza zakresu dokładnie zapisywalnego w double (2^53) dajemy jako napis, żeby żaden parser JSON ich nie zaokrąglił */
        int big = sv > 9007199254740992LL || sv < -9007199254740992LL;
        snprintf(tmp, sizeof(tmp), big ? "\"%lld\"" : "%lld", sv);
        sb_str(&r->out, tmp);
        return 1;
    }
    case TT_DOUBLE: {
        uint64_t v; if (!rd_u64(r, &v)) return 0;
        double d; memcpy(&d, &v, 8);
        if (d != d || d > 1e308 || d < -1e308) sb_str(&r->out, "null");
        else { snprintf(tmp, sizeof(tmp), "%.17g", d); sb_str(&r->out, tmp); }
        return 1;
    }
    case TT_STRING: { const uint8_t *p; size_t n; if (!rd_bytes_field(r, &p, &n)) return 0; json_string(&r->out, p, n); return 1; }
    case TT_BYTES: { const uint8_t *p; size_t n; if (!rd_bytes_field(r, &p, &n)) return 0; json_hex(&r->out, p, n); return 1; }
    case TT_INT128: if (r->pos + 16 > r->len) return rd_fail(r, "koniec danych", 0); json_hex(&r->out, r->d + r->pos, 16); r->pos += 16; return 1;
    case TT_INT256: if (r->pos + 32 > r->len) return rd_fail(r, "koniec danych", 0); json_hex(&r->out, r->d + r->pos, 32); r->pos += 32; return 1;
    case TT_BOOL: {
        uint32_t v; if (!rd_u32(r, &v)) return 0;
        if (v == BOOL_TRUE) sb_str(&r->out, "true"); else if (v == BOOL_FALSE) sb_str(&r->out, "false"); else return rd_fail(r, "zła wartość Bool", v);
        return 1;
    }
    case TT_TRUE: sb_str(&r->out, "true"); return 1;
    case TT_FLAGS: return rd_fail(r, "flagi poza strukturą", 0);
    case TT_VECTOR: {
        if (!t->bare_vec) {
            uint32_t id; if (!rd_u32(r, &id)) return 0;
            if (id != VECTOR_ID) return rd_fail(r, "oczekiwano wektora, jest", id);
        }
        uint32_t count; if (!rd_u32(r, &count)) return 0;
        if (count > 200000u) return rd_fail(r, "zbyt długi wektor", count);
        sb_ch(&r->out, '[');
        for (uint32_t i = 0; i < count; i++) {
            if (i) sb_ch(&r->out, ',');
            if (!rd_value(r, t->elem, depth + 1)) return 0;
        }
        sb_ch(&r->out, ']');
        return 1;
    }
    case TT_BARE: {
        const tl_con *c = find_first_of_type(r->s, t->tname);
        if (!c) return rd_fail(r, "nieznany typ bare", 0);
        return rd_object(r, c->id, 1, depth + 1);
    }
    default: {
        uint32_t id; if (!rd_u32(r, &id)) return 0;
        return rd_object(r, id, 1, depth + 1);
    }
    }
}

static int rd_object(rd *r, uint32_t id, int have_id, int depth)
{
    (void)have_id;
    if (depth > MAX_DEPTH) return rd_fail(r, "zbyt głębokie zagnieżdżenie", id);
    if (id == BOOL_TRUE) { sb_str(&r->out, "true"); return 1; }
    if (id == BOOL_FALSE) { sb_str(&r->out, "false"); return 1; }
    if (id == VECTOR_ID) {
        /* wektor bez znanego typu elementów: elementy muszą być obiektami z identyfikatorami */
        uint32_t count; if (!rd_u32(r, &count)) return 0;
        if (count > 200000u) return rd_fail(r, "zbyt długi wektor", count);
        sb_ch(&r->out, '[');
        for (uint32_t i = 0; i < count; i++) {
            uint32_t eid; if (i) sb_ch(&r->out, ',');
            if (!rd_u32(r, &eid)) return 0;
            if (!rd_object(r, eid, 1, depth + 1)) return 0;
        }
        sb_ch(&r->out, ']');
        return 1;
    }
    const tl_con *c = find_id(r->s, id);
    if (!c) return rd_fail(r, "nieznany konstruktor", id);
    uint32_t *flagvals = (uint32_t *)calloc((size_t)c->nparams + 1, sizeof(uint32_t));
    if (!flagvals) return rd_fail(r, "brak pamięci", id);
    sb_str(&r->out, "{\"_\":");
    json_string(&r->out, (const uint8_t *)c->name, strlen(c->name));
    for (int i = 0; i < c->nparams; i++) {
        const tl_param *p = &c->params[i];
        if (p->type->kind == TT_FLAGS) {
            if (!rd_u32(r, &flagvals[i])) { free(flagvals); return 0; }
            continue;
        }
        if (p->flagvar >= 0) {
            if (!((flagvals[p->flagvar] >> p->flagbit) & 1u)) continue;
        }
        sb_ch(&r->out, ',');
        json_string(&r->out, (const uint8_t *)p->name, strlen(p->name));
        sb_ch(&r->out, ':');
        if (!rd_value(r, p->type, depth)) { free(flagvals); return 0; }
    }
    free(flagvals);
    sb_ch(&r->out, '}');
    return 1;
}

static int finish_read(rd *r, int ok, char **json, size_t *used, char *err, int errlen)
{
    if (!ok || r->out.oom) {
        if (err && errlen > 0) snprintf(err, (size_t)errlen, "%s", r->err[0] ? r->err : "błąd odczytu TL");
        free(r->out.p);
        return -1;
    }
    *json = r->out.p;
    if (used) *used = r->pos;
    return 0;
}

int tl_read_json(const tl_schema *s, const uint8_t *data, size_t len, char **json, size_t *used, char *err, int errlen)
{
    rd r;
    memset(&r, 0, sizeof(r));
    r.s = s; r.d = data; r.len = len;
    uint32_t id;
    int ok = rd_u32(&r, &id) && rd_object(&r, id, 1, 0);
    return finish_read(&r, ok, json, used, err, errlen);
}

int tl_read_result_json(const tl_schema *s, const char *function, const uint8_t *data, size_t len, char **json, size_t *used, char *err, int errlen)
{
    const tl_con *f = find_name(s, function);
    rd r;
    memset(&r, 0, sizeof(r));
    r.s = s; r.d = data; r.len = len;
    int ok;
    if (f && f->rtype && (strncmp(f->rtype, "Vector<", 7) == 0 || strncmp(f->rtype, "vector<", 7) == 0)) {
        tl_type *t = type_parse(f->rtype, strlen(f->rtype));
        ok = t && rd_value(&r, t, 0);
        type_free(t);
    } else {
        uint32_t id;
        ok = rd_u32(&r, &id) && rd_object(&r, id, 1, 0);
    }
    return finish_read(&r, ok, json, used, err, errlen);
}

/* ---------------- JSON -> drzewo ---------------- */

enum { J_NULL, J_BOOL, J_INT, J_DBL, J_STR, J_ARR, J_OBJ };

typedef struct jv {
    int type;
    int64_t i;
    double d;
    char *s; size_t slen;
    struct jv **items;
    char **keys;
    int n, cap;
} jv;

typedef struct { const char *p, *end; char err[96]; } jp;

static void jv_free(jv *v)
{
    if (!v) return;
    free(v->s);
    for (int i = 0; i < v->n; i++) { jv_free(v->items[i]); if (v->keys) free(v->keys[i]); }
    free(v->items);
    free(v->keys);
    free(v);
}

static void jp_ws(jp *p) { while (p->p < p->end && (*p->p == ' ' || *p->p == '\n' || *p->p == '\t' || *p->p == '\r')) p->p++; }

static jv *jv_new(int type)
{
    jv *v = (jv *)calloc(1, sizeof(jv));
    if (v) v->type = type;
    return v;
}

static int jv_push(jv *a, jv *item, char *key)
{
    if (a->n == a->cap) {
        int ncap = a->cap ? a->cap * 2 : 8;
        jv **ni = (jv **)realloc(a->items, (size_t)ncap * sizeof(jv *));
        if (!ni) return 0;
        a->items = ni;
        if (a->type == J_OBJ) {
            char **nk = (char **)realloc(a->keys, (size_t)ncap * sizeof(char *));
            if (!nk) return 0;
            a->keys = nk;
        }
        a->cap = ncap;
    }
    a->items[a->n] = item;
    if (a->type == J_OBJ) a->keys[a->n] = key;
    a->n++;
    return 1;
}

static void put_utf8(sbuf *b, uint32_t cp)
{
    char c[4];
    if (cp < 0x80) { c[0] = (char)cp; sb_put(b, c, 1); }
    else if (cp < 0x800) { c[0] = (char)(0xc0 | (cp >> 6)); c[1] = (char)(0x80 | (cp & 63)); sb_put(b, c, 2); }
    else if (cp < 0x10000) { c[0] = (char)(0xe0 | (cp >> 12)); c[1] = (char)(0x80 | ((cp >> 6) & 63)); c[2] = (char)(0x80 | (cp & 63)); sb_put(b, c, 3); }
    else { c[0] = (char)(0xf0 | (cp >> 18)); c[1] = (char)(0x80 | ((cp >> 12) & 63)); c[2] = (char)(0x80 | ((cp >> 6) & 63)); c[3] = (char)(0x80 | (cp & 63)); sb_put(b, c, 4); }
}

static int jp_hex4(jp *p, uint32_t *out)
{
    if (p->p + 4 > p->end) return 0;
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) { int h = hexval(p->p[i]); if (h < 0) return 0; v = (v << 4) | (uint32_t)h; }
    p->p += 4;
    *out = v;
    return 1;
}

static int jp_string(jp *p, char **out, size_t *outlen)
{
    sbuf b;
    memset(&b, 0, sizeof(b));
    p->p++;                                                   /* otwierający " */
    while (p->p < p->end && *p->p != '"') {
        if (*p->p == '\\') {
            p->p++;
            if (p->p >= p->end) break;
            char c = *p->p++;
            switch (c) {
            case 'n': sb_ch(&b, '\n'); break;
            case 't': sb_ch(&b, '\t'); break;
            case 'r': sb_ch(&b, '\r'); break;
            case 'b': sb_ch(&b, '\b'); break;
            case 'f': sb_ch(&b, '\f'); break;
            case 'u': {
                uint32_t cp;
                if (!jp_hex4(p, &cp)) { free(b.p); return 0; }
                if (cp >= 0xd800 && cp < 0xdc00 && p->p + 6 <= p->end && p->p[0] == '\\' && p->p[1] == 'u') {
                    p->p += 2;
                    uint32_t lo;
                    if (!jp_hex4(p, &lo)) { free(b.p); return 0; }
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                }
                put_utf8(&b, cp);
                break;
            }
            default: sb_ch(&b, c); break;
            }
        } else {
            sb_ch(&b, *p->p++);
        }
    }
    if (p->p >= p->end) { free(b.p); return 0; }
    p->p++;                                                   /* zamykający " */
    if (!b.p) { b.p = (char *)malloc(1); if (!b.p) return 0; b.p[0] = 0; }
    *out = b.p;
    *outlen = b.n;
    return !b.oom;
}

static jv *jp_value(jp *p, int depth);

static jv *jp_value(jp *p, int depth)
{
    if (depth > 64) { snprintf(p->err, sizeof(p->err), "zbyt głęboki JSON"); return NULL; }
    jp_ws(p);
    if (p->p >= p->end) { snprintf(p->err, sizeof(p->err), "nieoczekiwany koniec JSON"); return NULL; }
    char c = *p->p;
    if (c == '{') {
        jv *o = jv_new(J_OBJ);
        p->p++;
        jp_ws(p);
        if (p->p < p->end && *p->p == '}') { p->p++; return o; }
        for (;;) {
            jp_ws(p);
            if (p->p >= p->end || *p->p != '"') { snprintf(p->err, sizeof(p->err), "oczekiwano klucza"); jv_free(o); return NULL; }
            char *key; size_t kl;
            if (!jp_string(p, &key, &kl)) { snprintf(p->err, sizeof(p->err), "zły klucz"); jv_free(o); return NULL; }
            jp_ws(p);
            if (p->p >= p->end || *p->p != ':') { free(key); snprintf(p->err, sizeof(p->err), "oczekiwano :"); jv_free(o); return NULL; }
            p->p++;
            jv *val = jp_value(p, depth + 1);
            if (!val) { free(key); jv_free(o); return NULL; }
            if (!jv_push(o, val, key)) { free(key); jv_free(val); jv_free(o); return NULL; }
            jp_ws(p);
            if (p->p < p->end && *p->p == ',') { p->p++; continue; }
            if (p->p < p->end && *p->p == '}') { p->p++; return o; }
            snprintf(p->err, sizeof(p->err), "oczekiwano , lub }");
            jv_free(o);
            return NULL;
        }
    }
    if (c == '[') {
        jv *a = jv_new(J_ARR);
        p->p++;
        jp_ws(p);
        if (p->p < p->end && *p->p == ']') { p->p++; return a; }
        for (;;) {
            jv *val = jp_value(p, depth + 1);
            if (!val) { jv_free(a); return NULL; }
            if (!jv_push(a, val, NULL)) { jv_free(val); jv_free(a); return NULL; }
            jp_ws(p);
            if (p->p < p->end && *p->p == ',') { p->p++; continue; }
            if (p->p < p->end && *p->p == ']') { p->p++; return a; }
            snprintf(p->err, sizeof(p->err), "oczekiwano , lub ]");
            jv_free(a);
            return NULL;
        }
    }
    if (c == '"') {
        jv *v = jv_new(J_STR);
        if (!jp_string(p, &v->s, &v->slen)) { snprintf(p->err, sizeof(p->err), "zły napis"); jv_free(v); return NULL; }
        return v;
    }
    if ((size_t)(p->end - p->p) >= 4 && memcmp(p->p, "true", 4) == 0) { p->p += 4; jv *v = jv_new(J_BOOL); v->i = 1; return v; }
    if ((size_t)(p->end - p->p) >= 5 && memcmp(p->p, "false", 5) == 0) { p->p += 5; jv *v = jv_new(J_BOOL); v->i = 0; return v; }
    if ((size_t)(p->end - p->p) >= 4 && memcmp(p->p, "null", 4) == 0) { p->p += 4; return jv_new(J_NULL); }
    if (c == '-' || (c >= '0' && c <= '9')) {
        const char *st = p->p;
        int neg = 0, isint = 1;
        if (*p->p == '-') { neg = 1; p->p++; }
        uint64_t acc = 0;
        while (p->p < p->end && *p->p >= '0' && *p->p <= '9') { acc = acc * 10 + (uint64_t)(*p->p - '0'); p->p++; }
        if (p->p < p->end && (*p->p == '.' || *p->p == 'e' || *p->p == 'E')) {
            isint = 0;
            while (p->p < p->end && ((*p->p >= '0' && *p->p <= '9') || *p->p == '.' || *p->p == 'e' || *p->p == 'E' || *p->p == '+' || *p->p == '-')) p->p++;
        }
        jv *v;
        if (isint) { v = jv_new(J_INT); v->i = neg ? -(int64_t)acc : (int64_t)acc; }
        else {
            char tmp[64]; size_t l = (size_t)(p->p - st); if (l > 63) l = 63;
            memcpy(tmp, st, l); tmp[l] = 0;
            v = jv_new(J_DBL); v->d = strtod(tmp, NULL);
        }
        return v;
    }
    snprintf(p->err, sizeof(p->err), "nieoczekiwany znak w JSON");
    return NULL;
}

static const jv *jv_get(const jv *o, const char *key)
{
    if (!o || o->type != J_OBJ) return NULL;
    for (int i = 0; i < o->n; i++) if (strcmp(o->keys[i], key) == 0) return o->items[i];
    return NULL;
}

/* ---------------- zapis JSON -> TL ---------------- */

typedef struct { const tl_schema *s; sbuf out; char err[160]; } wr;

static int wr_fail(wr *w, const char *a, const char *b)
{
    if (!w->err[0]) snprintf(w->err, sizeof(w->err), "%s%s%s", a, b ? ": " : "", b ? b : "");
    return 0;
}

static void wr_bytes_field(wr *w, const uint8_t *p, size_t n)
{
    if (n < 254) {
        uint8_t l = (uint8_t)n;
        sb_put(&w->out, &l, 1);
    } else {
        uint8_t h[4] = { 254, (uint8_t)n, (uint8_t)(n >> 8), (uint8_t)(n >> 16) };
        sb_put(&w->out, h, 4);
    }
    sb_put(&w->out, p, n);
    size_t total = (n < 254 ? 1 : 4) + n;
    static const uint8_t zero[4] = { 0, 0, 0, 0 };
    size_t pad = ((total + 3) & ~(size_t)3) - total;
    if (pad) sb_put(&w->out, zero, pad);
}

static int wr_hex(wr *w, const jv *v, size_t want, uint8_t **out, size_t *outn)
{
    if (v->type != J_STR || (v->slen & 1)) return wr_fail(w, "oczekiwano napisu hex", NULL);
    size_t n = v->slen >> 1;
    if (want && n != want) return wr_fail(w, "zła długość pola hex", NULL);
    uint8_t *b = (uint8_t *)malloc(n ? n : 1);
    for (size_t i = 0; i < n; i++) {
        int h = hexval(v->s[2 * i]), l = hexval(v->s[2 * i + 1]);
        if (h < 0 || l < 0) { free(b); return wr_fail(w, "zły znak hex", NULL); }
        b[i] = (uint8_t)((h << 4) | l);
    }
    *out = b; *outn = n;
    return 1;
}

static int wr_object(wr *w, const jv *o, int depth);

static int wr_value(wr *w, const tl_type *t, const jv *v, int depth)
{
    if (depth > MAX_DEPTH) return wr_fail(w, "zbyt głębokie zagnieżdżenie", NULL);
    switch (t->kind) {
    case TT_INT:
        if (v->type != J_INT && v->type != J_BOOL) return wr_fail(w, "oczekiwano liczby int", NULL);
        sb_u32(&w->out, (uint32_t)(int32_t)v->i); return 1;
    case TT_LONG: {
        int64_t x;
        if (v->type == J_INT || v->type == J_BOOL) x = v->i;
        else if (v->type == J_STR) { x = 0; int neg = 0; const char *q = v->s; if (*q == '-') { neg = 1; q++; } while (*q >= '0' && *q <= '9') { x = x * 10 + (*q - '0'); q++; } if (neg) x = -x; }
        else return wr_fail(w, "oczekiwano liczby long", NULL);
        sb_u64(&w->out, (uint64_t)x); return 1;
    }
    case TT_DOUBLE: {
        double d;
        if (v->type == J_DBL) d = v->d;
        else {   /* bez konwersji 64-bit -> double (jej nie ma w iOS 6): składamy z dwóch połówek 32-bitowych */
            int64_t iv = (int64_t)v->i;
            d = (double)(int32_t)(iv >> 32) * 4294967296.0 + (double)(uint32_t)iv;
        }
        uint64_t b; memcpy(&b, &d, 8); sb_u64(&w->out, b); return 1;
    }
    case TT_STRING:
        if (v->type != J_STR) return wr_fail(w, "oczekiwano napisu", NULL);
        wr_bytes_field(w, (const uint8_t *)v->s, v->slen); return 1;
    case TT_BYTES: {
        uint8_t *b; size_t n;
        if (!wr_hex(w, v, 0, &b, &n)) return 0;
        wr_bytes_field(w, b, n); free(b); return 1;
    }
    case TT_INT128: case TT_INT256: {
        uint8_t *b; size_t n;
        if (!wr_hex(w, v, t->kind == TT_INT128 ? 16 : 32, &b, &n)) return 0;
        sb_put(&w->out, b, n); free(b); return 1;
    }
    case TT_BOOL:
        if (v->type != J_BOOL) return wr_fail(w, "oczekiwano true/false", NULL);
        sb_u32(&w->out, v->i ? BOOL_TRUE : BOOL_FALSE); return 1;
    case TT_TRUE: return 1;
    case TT_VECTOR:
        if (v->type != J_ARR) return wr_fail(w, "oczekiwano tablicy", NULL);
        if (!t->bare_vec) sb_u32(&w->out, VECTOR_ID);
        sb_u32(&w->out, (uint32_t)v->n);
        for (int i = 0; i < v->n; i++) if (!wr_value(w, t->elem, v->items[i], depth + 1)) return 0;
        return 1;
    default:
        if (v->type == J_BOOL && t->kind == TT_OBJECT && t->tname && strcmp(t->tname, "Bool") == 0) { sb_u32(&w->out, v->i ? BOOL_TRUE : BOOL_FALSE); return 1; }
        if (v->type != J_OBJ) return wr_fail(w, "oczekiwano obiektu dla typu", t->tname ? t->tname : "?");
        return wr_object(w, v, depth + 1);
    }
}

static int wr_object(wr *w, const jv *o, int depth)
{
    const jv *nm = jv_get(o, "_raw");
    if (nm) {
        uint8_t *b; size_t n;
        if (!wr_hex(w, nm, 0, &b, &n)) return 0;
        sb_put(&w->out, b, n); free(b);
        return 1;
    }
    nm = jv_get(o, "_");
    if (!nm || nm->type != J_STR) return wr_fail(w, "brak pola \"_\" z nazwą konstruktora", NULL);
    const tl_con *c = find_name(w->s, nm->s);
    if (!c) return wr_fail(w, "nieznany konstruktor", nm->s);
    sb_u32(&w->out, c->id);
    uint32_t *flagvals = (uint32_t *)calloc((size_t)c->nparams + 1, sizeof(uint32_t));
    if (!flagvals) return wr_fail(w, "brak pamięci", NULL);
    for (int i = 0; i < c->nparams; i++) {
        const tl_param *p = &c->params[i];
        if (p->flagvar < 0) continue;
        const jv *val = jv_get(o, p->name);
        int present = val && val->type != J_NULL;
        if (present && p->type->kind == TT_TRUE) present = (val->type == J_BOOL && val->i);
        if (present) flagvals[p->flagvar] |= 1u << p->flagbit;
    }
    for (int i = 0; i < c->nparams; i++) {
        const tl_param *p = &c->params[i];
        if (p->type->kind == TT_FLAGS) { sb_u32(&w->out, flagvals[i]); continue; }
        if (p->flagvar >= 0 && !((flagvals[p->flagvar] >> p->flagbit) & 1u)) continue;
        if (p->type->kind == TT_TRUE) continue;
        const jv *val = jv_get(o, p->name);
        if (!val || val->type == J_NULL) { char buf[96]; snprintf(buf, sizeof(buf), "%s.%s", c->name, p->name); free(flagvals); return wr_fail(w, "brakuje pola", buf); }
        if (!wr_value(w, p->type, val, depth)) {
            free(flagvals);
            if (w->err[0] && !strchr(w->err, '@')) { size_t l = strlen(w->err); if (l + strlen(p->name) + 4 < sizeof(w->err)) { w->err[l] = ' '; w->err[l + 1] = '@'; strcpy(w->err + l + 2, p->name); } }
            return 0;
        }
    }
    free(flagvals);
    return 1;
}

int tl_write_json(const tl_schema *s, const char *json, uint8_t **out, size_t *outlen, char *err, int errlen)
{
    jp p;
    memset(&p, 0, sizeof(p));
    p.p = json; p.end = json + strlen(json);
    jv *root = jp_value(&p, 0);
    if (!root) { if (err && errlen > 0) snprintf(err, (size_t)errlen, "JSON: %s", p.err); return -1; }
    wr w;
    memset(&w, 0, sizeof(w));
    w.s = s;
    int ok = root->type == J_OBJ ? wr_object(&w, root, 0) : wr_fail(&w, "korzeń JSON musi być obiektem", NULL);
    jv_free(root);
    if (!ok || w.out.oom) {
        if (err && errlen > 0) snprintf(err, (size_t)errlen, "%s", w.err[0] ? w.err : "błąd zapisu TL");
        free(w.out.p);
        return -1;
    }
    if (!w.out.p) { w.out.p = (char *)malloc(1); }
    *out = (uint8_t *)w.out.p;
    *outlen = w.out.n;
    return 0;
}
