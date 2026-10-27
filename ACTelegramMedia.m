#import "ACTelegramPrivate.h"
#import "ACStore.h"
#import "ACMedia.h"
#include <string.h>
#include "tg_mt.h"

NSString *const ACTGMediaDidChangeNotification = @"ACTGMediaDidChange";

/* Załączniki leżą na różnych serwerach (DC) Telegrama. Konto jest na jednym, a do pozostałych otwieramy
   dodatkowe, krótkie połączenie: wymiana kluczy + auth.exportAuthorization / importAuthorization. */

/* ===================== dodatkowe połączenie do innego DC ===================== */

@class ACTGLink;
static void lkResult(void *ud, uint32_t tok, const uint8_t *tl, size_t len);
static void lkError(void *ud, uint32_t tok, int code, const char *msg);
static void lkUpdate(void *ud, const uint8_t *tl, size_t len);
static void lkClosed(void *ud, const char *why);

@interface ACTGLinkCall : NSObject
@property (nonatomic, copy) ACTGDone done;
@end
@implementation ACTGLinkCall
@end

@interface ACTGLink : NSObject {
    tg_conn *_conn;
    NSMutableDictionary *_calls;
}
@property (nonatomic) int dc;
@property (nonatomic) BOOL ready, closed, needInit, usedSaved, connecting;
@property (nonatomic, copy) void (^onClosed)(ACTGLink *);
- (void)openWithDone:(void (^)(NSString *err))done;
- (void)call:(NSDictionary *)obj done:(ACTGDone)done;
- (void)saveAuth;
- (void)shutdown;
- (void)gotResult:(NSData *)d token:(uint32_t)tok;
- (void)gotError:(NSString *)msg code:(int)code token:(uint32_t)tok;
- (void)gotClosed:(NSString *)why;
@end

static void lkResult(void *ud, uint32_t tok, const uint8_t *tl, size_t len)
{
    [(__bridge ACTGLink *)ud gotResult:[NSData dataWithBytes:tl length:len] token:tok];
}
static void lkError(void *ud, uint32_t tok, int code, const char *msg)
{
    [(__bridge ACTGLink *)ud gotError:[NSString stringWithUTF8String:msg ? msg : ""] code:code token:tok];
}
static void lkUpdate(void *ud, const uint8_t *tl, size_t len) { /* na dodatkowych połączeniach aktualizacje nie są potrzebne */ }
static void lkClosed(void *ud, const char *why)
{
    [(__bridge ACTGLink *)ud gotClosed:[NSString stringWithUTF8String:why ? why : ""]];
}

@implementation ACTGLink {
    uint8_t _key[256];
    uint64_t _salt;
    int32_t _off;
    BOOL _haveAuth;
}

- (id)init
{
    if ((self = [super init])) _calls = [NSMutableDictionary dictionary];
    return self;
}

- (void)openWithDone:(void (^)(NSString *err))done
{
    ACTelegram *tg = [ACTelegram shared];
    NSString *ip = [tg ipForDC:_dc];
    NSDictionary *saved = [[[ACStore shared] objectForKey:@"tg.mk"] objectForKey:[NSString stringWithFormat:@"%d", _dc]];
    NSData *sk = [saved objectForKey:@"key"];
    BOOL useSaved = [sk length] == 256;
    unsigned long long ssalt = [[saved objectForKey:@"salt"] unsignedLongLongValue];
    int soff = [[saved objectForKey:@"off"] intValue];
    _usedSaved = useSaved;
    _connecting = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        tg_events ev;
        memset(&ev, 0, sizeof(ev));
        ev.ud = (__bridge void *)self;
        ev.on_result = lkResult;
        ev.on_error = lkError;
        ev.on_update = lkUpdate;
        ev.on_closed = lkClosed;
        tg_conn *c = tg_conn_new(&ev);
        char err[200];
        err[0] = 0;
        NSString *failure = nil;
        if (!c) failure = @"Brak pamięci.";
        else if (tg_conn_open(c, [ip UTF8String], 443, 10000, err, sizeof(err)) != 0) failure = [NSString stringWithFormat:@"Nie można połączyć z serwerem plików (%s).", err];
        else if (useSaved) tg_conn_set_auth(c, (const uint8_t *)[sk bytes], (uint64_t)ssalt, (int32_t)soff);
        else if (tg_conn_handshake(c, err, sizeof(err)) != 0) failure = [NSString stringWithFormat:@"Wymiana kluczy z serwerem plików nie powiodła się: %s", err];
        if (failure) {
            if (c) tg_conn_free(c);
            dispatch_async(dispatch_get_main_queue(), ^{ _connecting = NO; _closed = YES; if (done) done(failure); });
            return;
        }
        uint64_t salt = 0;
        int32_t off = 0;
        uint8_t key[256];
        BOOL have = tg_conn_get_auth(c, key, &salt, &off) != 0;
        @synchronized(self) {
            _conn = c;
            if (have) { memcpy(_key, key, 256); _salt = salt; _off = off; _haveAuth = YES; }
            _needInit = YES;
        }
        NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        [t setStackSize:1024 * 1024];
        [t start];
        dispatch_async(dispatch_get_main_queue(), ^{ _connecting = NO; if (done) done(nil); });
    });
}

- (void)run
{
    tg_conn *c;
    @synchronized(self) { c = _conn; }
    if (!c) return;
    tg_conn_run(c);
    @synchronized(self) {
        _conn = NULL;
        tg_conn_free(c);
    }
}

- (void)saveAuth
{
    NSData *k;
    uint64_t salt;
    int32_t off;
    @synchronized(self) {
        if (!_haveAuth) return;
        k = [NSData dataWithBytes:_key length:256];
        salt = _salt;
        off = _off;
    }
    ACStore *st = [ACStore shared];
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:[st objectForKey:@"tg.mk"]];
    NSDictionary *e = [NSDictionary dictionaryWithObjectsAndKeys:k, @"key", [NSNumber numberWithUnsignedLongLong:salt], @"salt", [NSNumber numberWithInt:off], @"off", nil];
    [all setObject:e forKey:[NSString stringWithFormat:@"%d", _dc]];
    [st setObject:all forKey:@"tg.mk"];
}

- (void)call:(NSDictionary *)obj done:(ACTGDone)done
{
    ACTelegram *tg = [ACTelegram shared];
    NSString *fail = nil;
    @synchronized(self) {
        if (!_conn || _closed) fail = @"Połączenie z serwerem plików zostało zamknięte.";
        else {
            NSDictionary *send = obj;
            BOOL wrapped = NO;
            if (_needInit) { send = [tg wrapInit:obj]; wrapped = YES; }
            NSString *encErr = nil;
            NSData *bin = [tg encode:send error:&encErr];
            if (!bin) fail = encErr ? encErr : @"Błąd kodowania zapytania.";
            else {
                uint32_t tok = tg_conn_request(_conn, (const uint8_t *)[bin bytes], [bin length]);
                if (!tok) fail = @"Nie udało się wysłać zapytania.";
                else {
                    if (wrapped) _needInit = NO;
                    ACTGLinkCall *c = [[ACTGLinkCall alloc] init];
                    c.done = done;
                    [_calls setObject:c forKey:[NSNumber numberWithUnsignedInt:tok]];
                }
            }
        }
    }
    if (fail && done) done(nil, fail, -1);
}

- (void)gotResult:(NSData *)d token:(uint32_t)tok
{
    ACTGLinkCall *c;
    @synchronized(self) {
        NSNumber *k = [NSNumber numberWithUnsignedInt:tok];
        c = [_calls objectForKey:k];
        [_calls removeObjectForKey:k];
    }
    ACTGDone done = c.done;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(d, nil, 0); });
}

- (void)gotError:(NSString *)msg code:(int)code token:(uint32_t)tok
{
    ACTGLinkCall *c;
    @synchronized(self) {
        NSNumber *k = [NSNumber numberWithUnsignedInt:tok];
        c = [_calls objectForKey:k];
        [_calls removeObjectForKey:k];
    }
    ACTGDone done = c.done;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil, msg, code); });
}

- (void)gotClosed:(NSString *)why
{
    NSArray *all;
    @synchronized(self) {
        _closed = YES;
        all = [_calls allValues];
        [_calls removeAllObjects];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (ACTGLinkCall *c in all) { ACTGDone d = c.done; if (d) d(nil, @"Połączenie z serwerem plików zostało przerwane.", -1); }
        if (_onClosed) _onClosed(self);
    });
}

- (void)shutdown
{
    @synchronized(self) {
        _closed = YES;
        if (_conn) tg_conn_close(_conn);
    }
}

@end

/* ===================== zadania pobierania ===================== */

@interface ACTGJob : NSObject
@property (nonatomic, strong) ACMedia *media;
@property (nonatomic) BOOL thumb, retried401, retriedRef, retriedDC;
@property (nonatomic) int offset;
@property (nonatomic, strong) NSFileHandle *fh;
@property (nonatomic, copy) NSString *part, *dest;
@property (nonatomic, strong) ACTGLink *link;
@property (nonatomic) int lastPct;
@end
@implementation ACTGJob
@end

static NSMutableDictionary *gLinks;        /* "dc" -> ACTGLink */
static NSMutableDictionary *gWaiters;      /* "dc" -> NSMutableArray bloków */
static NSMutableArray *gThumbQueue;        /* ACMedia czekające na pobranie miniatury */
static int gThumbActive;

typedef void (^ACTGLinkReady)(ACTGLink *link, NSString *err);

static NSData *UploadBytes(NSData *raw, NSString **err)
{
    const uint8_t *p = (const uint8_t *)[raw bytes];
    NSUInteger n = [raw length];
    if (n < 16) { *err = @"Pusta odpowiedź serwera plików."; return nil; }
    uint32_t ctor = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    if (ctor == 0xf18cda44u) { *err = @"Ten plik leży na serwerze CDN, którego AeroChat jeszcze nie obsługuje."; return nil; }
    if (ctor != 0x096a18d5u) { *err = @"Nieoczekiwana odpowiedź serwera plików."; return nil; }
    NSUInteger o = 12;
    NSUInteger len;
    if (p[o] < 254) { len = p[o]; o += 1; }
    else { len = (NSUInteger)p[o + 1] | ((NSUInteger)p[o + 2] << 8) | ((NSUInteger)p[o + 3] << 16); o += 4; }
    if (o + len > n) { *err = @"Uszkodzona odpowiedź serwera plików."; return nil; }
    return [NSData dataWithBytes:p + o length:len];
}

static NSString *PLFileError(NSString *msg, int code)
{
    if ([msg hasPrefix:@"FLOOD_WAIT"]) return @"Telegram prosi o chwilę przerwy. Spróbuj za moment.";
    if ([msg hasPrefix:@"FILE_REFERENCE"]) return @"Załącznik wygasł na serwerze. Wejdź w rozmowę jeszcze raz i spróbuj ponownie.";
    if ([msg isEqualToString:@"LOCATION_INVALID"] || [msg isEqualToString:@"FILE_ID_INVALID"]) return @"Telegram nie udostępnia tego pliku.";
    if (code == -1 || code == -2 || code == -3) return msg;
    return [NSString stringWithFormat:@"Błąd Telegramu: %@", msg];
}

@implementation ACTelegram (Media)

- (void)postMedia:(ACMedia *)m relayout:(BOOL)relayout
{
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:m, @"media", [NSNumber numberWithBool:relayout], @"relayout", nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ACTGMediaDidChangeNotification object:self userInfo:info];
}

/* ---------- połączenia do innych DC ---------- */

- (void)flushWaitersForDC:(int)dc link:(ACTGLink *)link error:(NSString *)err
{
    NSString *k = [NSString stringWithFormat:@"%d", dc];
    NSArray *w = [gWaiters objectForKey:k];
    [gWaiters removeObjectForKey:k];
    for (ACTGLinkReady cb in w) cb(err ? nil : link, err);
}

- (void)dropLink:(ACTGLink *)link
{
    NSString *k = [NSString stringWithFormat:@"%d", link.dc];
    if ([gLinks objectForKey:k] == link) [gLinks removeObjectForKey:k];
    [link shutdown];
}

- (void)forgetSavedAuthForDC:(int)dc
{
    ACStore *st = [ACStore shared];
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:[st objectForKey:@"tg.mk"]];
    [all removeObjectForKey:[NSString stringWithFormat:@"%d", dc]];
    [st setObject:[all count] ? all : nil forKey:@"tg.mk"];
}

- (void)linkForDC:(int)dc ready:(ACTGLinkReady)cb
{
    if (!gLinks) { gLinks = [NSMutableDictionary dictionary]; gWaiters = [NSMutableDictionary dictionary]; }
    NSString *k = [NSString stringWithFormat:@"%d", dc];
    ACTGLink *link = [gLinks objectForKey:k];
    if (link && link.ready && !link.closed) { cb(link, nil); return; }
    NSMutableArray *w = [gWaiters objectForKey:k];
    if (!w) { w = [NSMutableArray array]; [gWaiters setObject:w forKey:k]; }
    [w addObject:[cb copy]];
    if (link && link.connecting) return;
    if (link) [self dropLink:link];

    link = [[ACTGLink alloc] init];
    link.dc = dc;
    [gLinks setObject:link forKey:k];
    __weak ACTGLink *wl = link;
    link.onClosed = ^(ACTGLink *l) { if ([gLinks objectForKey:k] == l) [gLinks removeObjectForKey:k]; };
    ACTGLink *strongLink = link;
    [link openWithDone:^(NSString *err) {
        if (err) { [self dropLink:strongLink]; [self flushWaitersForDC:dc link:nil error:err]; return; }
        if (strongLink.usedSaved) { strongLink.ready = YES; [self flushWaitersForDC:dc link:strongLink error:nil]; return; }
        /* nowy klucz: przenosimy autoryzację konta na ten DC */
        NSDictionary *exp = [NSDictionary dictionaryWithObjectsAndKeys:@"auth.exportAuthorization", @"_", [NSNumber numberWithInt:dc], @"dc_id", nil];
        [self call:exp done:^(id res, NSString *e1, int c1) {
            NSDictionary *r = [res isKindOfClass:[NSDictionary class]] ? res : nil;
            if (e1 || !r) {
                [self dropLink:strongLink];
                [self flushWaitersForDC:dc link:nil error:PLFileError(e1 ? e1 : @"Brak odpowiedzi.", c1)];
                return;
            }
            NSDictionary *imp = [NSDictionary dictionaryWithObjectsAndKeys:@"auth.importAuthorization", @"_",
                [r objectForKey:@"id"], @"id", [r objectForKey:@"bytes"], @"bytes", nil];
            [wl call:imp done:^(id res2, NSString *e2, int c2) {
                if (e2) {
                    [self dropLink:strongLink];
                    [self flushWaitersForDC:dc link:nil error:PLFileError(e2, c2)];
                    return;
                }
                [strongLink saveAuth];
                strongLink.ready = YES;
                [self flushWaitersForDC:dc link:strongLink error:nil];
            }];
        }];
    }];
}

- (void)mediaSessionEnded
{
    NSArray *links = [gLinks allValues];
    [gLinks removeAllObjects];
    for (ACTGLink *l in links) [l shutdown];
    NSArray *dcs = [gWaiters allKeys];
    for (NSString *k in dcs) [self flushWaitersForDC:[k intValue] link:nil error:@"Połączenie zamknięte."];
}

- (void)mediaWipe
{
    [[NSFileManager defaultManager] removeItemAtPath:[ACMedia cacheDirectory] error:nil];
    [[ACStore shared] setObject:nil forKey:@"tg.mk"];
    [gThumbQueue removeAllObjects];
}

/* ---------- pobieranie kawałkami ---------- */

- (NSDictionary *)locationForJob:(ACTGJob *)j
{
    ACMedia *m = j.media;
    NSString *size = j.thumb ? m.thumbType : (m.isDocument ? @"" : m.fullType);
    return [NSDictionary dictionaryWithObjectsAndKeys:
        m.isDocument ? @"inputDocumentFileLocation" : @"inputPhotoFileLocation", @"_",
        [NSNumber numberWithLongLong:m.mediaId], @"id",
        [NSNumber numberWithLongLong:m.accessHash], @"access_hash",
        m.fileRef ? m.fileRef : @"", @"file_reference",
        size ? size : @"", @"thumb_size", nil];
}

- (void)jobStep:(ACTGJob *)j
{
    ACMedia *m = j.media;
    int limit = j.thumb ? 131072 : 262144;
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"upload.getFile", @"_",
        [self locationForJob:j], @"location",
        [NSNumber numberWithInt:j.offset], @"offset",
        [NSNumber numberWithInt:limit], @"limit", nil];
    ACTGDone cb = ^(id res, NSString *err, int code) { [self jobChunk:j res:res err:err code:code limit:limit]; };
    int dc = m.dc > 0 ? m.dc : [self homeDC];
    if (dc == [self homeDC]) {
        j.link = nil;
        if (![self connectedHome]) { cb(nil, @"Brak połączenia z Telegramem.", -1); return; }
        [self callRaw:req done:cb];
    } else {
        [self linkForDC:dc ready:^(ACTGLink *l, NSString *e) {
            if (e) { cb(nil, e, -1); return; }
            j.link = l;
            [l call:req done:cb];
        }];
    }
}

- (void)jobFail:(ACTGJob *)j message:(NSString *)msg
{
    ACMedia *m = j.media;
    [j.fh closeFile];
    j.fh = nil;
    if (j.part) [[NSFileManager defaultManager] removeItemAtPath:j.part error:nil];
    if (j.thumb) {
        m.thumbTries++;
        m.thumbState = m.thumbTries >= 3 ? 3 : 0;
        gThumbActive--;
        [self pumpThumbs];
        if (m.thumbState == 3) [self postMedia:m relayout:YES];
    } else {
        m.state = ACMediaFailed;
        m.error = msg;
        m.openMode = 0;
        [self postMedia:m relayout:NO];
    }
}

- (void)jobFinish:(ACTGJob *)j
{
    ACMedia *m = j.media;
    [j.fh closeFile];
    j.fh = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:j.dest error:nil];
    NSError *e = nil;
    if (![fm moveItemAtPath:j.part toPath:j.dest error:&e]) { [self jobFail:j message:@"Nie można zapisać pliku na telefonie."]; return; }
    if (j.thumb) {
        gThumbActive--;
        UIImage *img = [UIImage imageWithContentsOfFile:j.dest];
        if (img) { m.thumb = img; m.thumbState = 2; [self postMedia:m relayout:NO]; }
        else { [fm removeItemAtPath:j.dest error:nil]; m.thumbState = 3; [self postMedia:m relayout:YES]; }
        [self pumpThumbs];
    } else {
        m.localPath = j.dest;
        m.state = ACMediaDone;
        m.progress = 1.0f;
        m.error = nil;
        [self postMedia:m relayout:NO];
    }
}

- (void)jobChunk:(ACTGJob *)j res:(id)res err:(NSString *)err code:(int)code limit:(int)limit
{
    ACMedia *m = j.media;
    if (err) {
        if (code == 401 && j.link && !j.retried401) {          /* serwer zapomniał klucz: zaczynamy ten DC od nowa */
            j.retried401 = YES;
            [self forgetSavedAuthForDC:j.link.dc];
            [self dropLink:j.link];
            j.link = nil;
            [self jobStep:j];
            return;
        }
        if ([err hasPrefix:@"FILE_MIGRATE_"] && !j.retriedDC) {
            j.retriedDC = YES;
            int ndc = [[err substringFromIndex:13] intValue];
            if (ndc > 0) { m.dc = ndc; [self jobStep:j]; return; }
        }
        if ([err hasPrefix:@"FILE_REFERENCE"] && !j.retriedRef && j.offset == 0 && m.msgId != 0) {
            j.retriedRef = YES;
            [self refreshFileRef:m done:^(BOOL ok) {
                if (ok) [self jobStep:j]; else [self jobFail:j message:PLFileError(err, code)];
            }];
            return;
        }
        [self jobFail:j message:PLFileError(err, code)];
        return;
    }
    NSString *perr = nil;
    NSData *bytes = UploadBytes(res, &perr);
    if (!bytes) { [self jobFail:j message:perr]; return; }
    NSUInteger n = [bytes length];
    if (n == 0 && j.offset == 0) { [self jobFail:j message:@"Telegram zwrócił pusty plik."]; return; }
    if (n > 0) {
        if (!j.fh) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:[j.part stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:j.part error:nil];
            [fm createFileAtPath:j.part contents:nil attributes:nil];
            j.fh = [NSFileHandle fileHandleForWritingAtPath:j.part];
            if (!j.fh) { [self jobFail:j message:@"Nie można zapisać pliku na telefonie."]; return; }
        }
        [j.fh writeData:bytes];
        j.offset += (int)n;
    }
    BOOL last = n < (NSUInteger)limit || (!j.thumb && m.size > 0 && j.offset >= m.size);
    if (last) { [self jobFinish:j]; return; }
    if (!j.thumb) {
        float pr = m.size > 0 ? (float)j.offset / (float)m.size : 0.0f;
        if (pr > 0.99f) pr = 0.99f;
        m.progress = pr;
        int pct = (int)(pr * 100.0f);
        if (pct != j.lastPct) { j.lastPct = pct; [self postMedia:m relayout:NO]; }
    }
    [self jobStep:j];
}

/* po wygaśnięciu file_reference: pobieramy wiadomość jeszcze raz */
- (void)refreshFileRef:(ACMedia *)m done:(void (^)(BOOL ok))done
{
    NSArray *ids = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"inputMessageID", @"_", [NSNumber numberWithInt:m.msgId], @"id", nil]];
    NSDictionary *req;
    if (m.peerKind == 3) {
        NSDictionary *ch = [NSDictionary dictionaryWithObjectsAndKeys:@"inputChannel", @"_", [NSNumber numberWithLongLong:m.peerId], @"channel_id",
                            [NSNumber numberWithLongLong:m.peerAccess], @"access_hash", nil];
        req = [NSDictionary dictionaryWithObjectsAndKeys:@"channels.getMessages", @"_", ch, @"channel", ids, @"id", nil];
    } else {
        req = [NSDictionary dictionaryWithObjectsAndKeys:@"messages.getMessages", @"_", ids, @"id", nil];
    }
    [self call:req done:^(id res, NSString *e, int c) {
        BOOL ok = NO;
        NSDictionary *r = [res isKindOfClass:[NSDictionary class]] ? res : nil;
        for (id o in [r objectForKey:@"messages"]) {
            NSDictionary *msg = [o isKindOfClass:[NSDictionary class]] ? o : nil;
            if ([[msg objectForKey:@"id"] intValue] != m.msgId) continue;
            ACMedia *nm = [ACMedia mediaFromJSON:[msg objectForKey:@"media"]];
            if (nm && nm.mediaId == m.mediaId && [nm.fileRef length]) { m.fileRef = nm.fileRef; ok = YES; }
        }
        done(ok);
    }];
}

/* ---------- miniatury ---------- */

- (void)pumpThumbs
{
    while (gThumbActive < 3 && [gThumbQueue count]) {
        ACMedia *m = [gThumbQueue objectAtIndex:0];
        [gThumbQueue removeObjectAtIndex:0];
        if (m.thumbState != 1) continue;
        gThumbActive++;
        ACTGJob *j = [[ACTGJob alloc] init];
        j.media = m;
        j.thumb = YES;
        j.dest = [m thumbPath];
        j.part = [j.dest stringByAppendingString:@".part"];
        [self jobStep:j];
    }
}

- (void)loadThumb:(ACMedia *)m
{
    if (m.thumb || m.thumbState == 1 || m.thumbState == 3 || ![m.thumbType length]) return;
    NSString *p = [m thumbPath];
    NSData *d = [NSData dataWithContentsOfFile:p];
    if ([d length]) {
        UIImage *img = [UIImage imageWithData:d];
        if (img) { m.thumb = img; m.thumbState = 2; return; }
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
    if (!self.authorized || ![self connectedHome]) return;
    if (!gThumbQueue) gThumbQueue = [NSMutableArray array];
    m.thumbState = 1;
    [gThumbQueue addObject:m];
    dispatch_async(dispatch_get_main_queue(), ^{ [self pumpThumbs]; });
}

/* ---------- pełny plik ---------- */

- (void)downloadMedia:(ACMedia *)m openMode:(int)mode
{
    m.openMode = mode;
    if (m.state == ACMediaLoading) return;
    NSString *dest = [m fullPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
        m.localPath = dest;
        m.state = ACMediaDone;
        m.progress = 1.0f;
        [self postMedia:m relayout:NO];
        return;
    }
    m.state = ACMediaLoading;
    m.progress = 0.0f;
    m.error = nil;
    m.localPath = nil;
    [self postMedia:m relayout:NO];
    ACTGJob *j = [[ACTGJob alloc] init];
    j.media = m;
    j.thumb = NO;
    j.dest = dest;
    j.part = [dest stringByAppendingString:@".part"];
    [self jobStep:j];
}

@end
