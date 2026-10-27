#import "ACTelegram.h"
#import "ACCall.h"
#import "ACTelegramPrivate.h"
#import "ACStore.h"
#import "ACConfig.h"
#import <UIKit/UIKit.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>
#include "tg_mt.h"
#include "tg_tl.h"
#include "tg_crypto.h"

NSString *const ACTGStateDidChangeNotification = @"ACTGStateDidChange";
NSString *const ACTGChatsDidChangeNotification = @"ACTGChatsDidChange";

#define TG_LAYER_FALLBACK 222

/* ---------- pomocnicze ---------- */

static NSString *Hex(NSData *d)
{
    static const char *dg = "0123456789abcdef";
    NSMutableString *s = [NSMutableString stringWithCapacity:[d length] * 2];
    const uint8_t *p = (const uint8_t *)[d bytes];
    for (NSUInteger i = 0; i < [d length]; i++) [s appendFormat:@"%c%c", dg[p[i] >> 4], dg[p[i] & 15]];
    return s;
}

static NSData *UnHex(NSString *s)
{
    NSUInteger n = [s length] / 2;
    NSMutableData *d = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)[d mutableBytes];
    for (NSUInteger i = 0; i < n; i++) {
        int v = 0;
        for (int k = 0; k < 2; k++) {
            unichar ch = [s characterAtIndex:i * 2 + (NSUInteger)k];
            int x = (ch >= '0' && ch <= '9') ? ch - '0' : (ch >= 'a' && ch <= 'f') ? ch - 'a' + 10 : (ch >= 'A' && ch <= 'F') ? ch - 'A' + 10 : 0;
            v = (v << 4) | x;
        }
        p[i] = (uint8_t)v;
    }
    return d;
}

static NSString *PLError(int code, NSString *msg)
{
    if (!msg) msg = @"";
    if ([msg isEqualToString:@"API_ID_INVALID"] || [msg isEqualToString:@"API_ID_PUBLISHED_FLOOD"]) return @"Nieprawidłowe api_id lub api_hash (sprawdź na my.telegram.org).";
    if ([msg hasPrefix:@"PHONE_NUMBER_INVALID"]) return @"Nieprawidłowy numer telefonu. Podaj go z numerem kraju, np. +48 600 123 456.";
    if ([msg hasPrefix:@"PHONE_NUMBER_BANNED"]) return @"Ten numer jest zablokowany w Telegramie.";
    if ([msg hasPrefix:@"PHONE_NUMBER_FLOOD"]) return @"Zbyt wiele prób dla tego numeru. Spróbuj później.";
    if ([msg hasPrefix:@"PHONE_CODE_INVALID"]) return @"Nieprawidłowy kod.";
    if ([msg hasPrefix:@"PHONE_CODE_EMPTY"]) return @"Wpisz kod.";
    if ([msg hasPrefix:@"PHONE_CODE_EXPIRED"]) return @"Kod wygasł. Poproś o nowy.";
    if ([msg hasPrefix:@"PASSWORD_HASH_INVALID"]) return @"Nieprawidłowe hasło.";
    if ([msg hasPrefix:@"SRP_ID_INVALID"] || [msg hasPrefix:@"SRP_PASSWORD_CHANGED"]) return @"Hasło zmieniło się w trakcie logowania. Spróbuj jeszcze raz.";
    if ([msg hasPrefix:@"FLOOD_WAIT_"]) return [NSString stringWithFormat:@"Zbyt wiele prób. Spróbuj za %@ s.", [msg substringFromIndex:11]];
    if ([msg hasPrefix:@"SEND_CODE_UNAVAILABLE"]) return @"Nie można wysłać kolejnego kodu. Poczekaj na ten, który już wysłano.";
    if ([msg isEqualToString:@"AUTH_KEY_UNREGISTERED"] || [msg isEqualToString:@"SESSION_REVOKED"] || [msg isEqualToString:@"AUTH_KEY_INVALID"] || [msg isEqualToString:@"USER_DEACTIVATED"] || [msg isEqualToString:@"SESSION_EXPIRED"])
        return @"Sesja wygasła. Zaloguj się ponownie.";
    if ([msg isEqualToString:@"PEER_FLOOD"]) return @"Telegram ograniczył wysyłanie wiadomości.";
    if ([msg hasPrefix:@"CHAT_WRITE_FORBIDDEN"] || [msg hasPrefix:@"USER_BANNED_IN_CHANNEL"]) return @"Nie możesz pisać w tym czacie.";
    if (code == -1) return @"Połączenie przerwane.";
    if ([msg length]) return [NSString stringWithFormat:@"Błąd Telegrama: %@", msg];
    return [NSString stringWithFormat:@"Błąd (%d).", code];
}

static NSDateFormatter *Fmt(NSString *f)
{
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:f];
    return df;
}

static NSString *TimeString(int date)
{
    static NSDateFormatter *hm, *dm, *ymd;
    if (!hm) { hm = Fmt(@"HH:mm"); dm = Fmt(@"d.MM"); ymd = Fmt(@"yyyyMMdd"); }
    if (date <= 0) return @"";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)date];
    NSDate *now = [NSDate date];
    if ([[ymd stringFromDate:d] isEqualToString:[ymd stringFromDate:now]]) return [hm stringFromDate:d];
    return [dm stringFromDate:d];
}

static NSString *WasOnline(int was)
{
    int now = (int)time(NULL);
    int diff = now - was;
    if (diff < 60) return @"był(a) przed chwilą";
    if (diff < 3600) return [NSString stringWithFormat:@"był(a) %d min temu", diff / 60];
    if (diff < 86400) return [NSString stringWithFormat:@"był(a) %d godz. temu", diff / 3600];
    return [NSString stringWithFormat:@"był(a) %@", TimeString(was)];
}

static NSString *LS(long long v) { return [NSString stringWithFormat:@"%lld", v]; }
static int IntOf(id o) { return [o respondsToSelector:@selector(intValue)] ? [o intValue] : 0; }
static long long LongOf(id o) { return [o respondsToSelector:@selector(longLongValue)] ? [o longLongValue] : 0; }
static BOOL BoolOf(id o) { return [o respondsToSelector:@selector(boolValue)] ? [o boolValue] : NO; }
static NSString *StrOf(id o) { return [o isKindOfClass:[NSString class]] ? o : @""; }
static NSDictionary *DictOf(id o) { return [o isKindOfClass:[NSDictionary class]] ? o : nil; }
static NSArray *ArrOf(id o) { return [o isKindOfClass:[NSArray class]] ? o : [NSArray array]; }

/* ---------- wywołanie oczekujące na odpowiedź ---------- */

@interface ACTGCall : NSObject
@property (nonatomic, copy) NSString *fn;
@property (nonatomic, copy) ACTGDone done;
@property (nonatomic) BOOL raw;
@end
@implementation ACTGCall
@end

/* ---------- klasa ---------- */

@interface ACTelegram ()
- (void)deliverResult:(NSData *)d token:(uint32_t)tok gen:(int)gen;
- (void)deliverError:(uint32_t)tok code:(int)code message:(NSString *)msg gen:(int)gen;
- (void)deliverUpdate:(NSData *)d gen:(int)gen;
- (void)connectionClosed:(NSString *)why gen:(int)gen;
@end

static void cbResult(void *ud, uint32_t tok, const uint8_t *tl, size_t len)
{
    [[ACTelegram shared] deliverResult:[NSData dataWithBytes:tl length:len] token:tok gen:(int)(intptr_t)ud];
}
static void cbError(void *ud, uint32_t tok, int code, const char *msg)
{
    [[ACTelegram shared] deliverError:tok code:code message:[NSString stringWithUTF8String:msg ? msg : ""] gen:(int)(intptr_t)ud];
}
static void cbUpdate(void *ud, const uint8_t *tl, size_t len)
{
    [[ACTelegram shared] deliverUpdate:[NSData dataWithBytes:tl length:len] gen:(int)(intptr_t)ud];
}
static void cbClosed(void *ud, const char *why)
{
    [[ACTelegram shared] connectionClosed:[NSString stringWithUTF8String:why ? why : ""] gen:(int)(intptr_t)ud];
}

@implementation ACTelegram {
    tl_schema *_schema;
    tg_conn *_conn;
    BOOL _connOK, _needInit, _connecting;
    int _gen;
    NSMutableDictionary *_calls;          /* token -> ACTGCall */
    int _dc;
    int _retry;
    BOOL _userClosed;

    ACTGState _state;
    BOOL _busy, _authorized, _syncing;
    NSString *_lastError, *_codeInfo, *_passwordHint, *_userName, *_phone, *_codeHash;
    long long _uid;
    NSMutableArray *_chats;
    NSMutableDictionary *_byKey;          /* "u123" -> ACChat */
    NSMutableDictionary *_users;          /* NSNumber id -> user JSON */
    NSMutableDictionary *_chatInfo;       /* "c123"/"h123" -> chat JSON */
}

@synthesize state = _state, busy = _busy, authorized = _authorized, lastError = _lastError, codeInfo = _codeInfo,
            passwordHint = _passwordHint, userName = _userName, phone = _phone, chats = _chats;

+ (ACTelegram *)shared
{
    static ACTelegram *s;
    if (!s) s = [[ACTelegram alloc] init];
    return s;
}

- (id)init
{
    if ((self = [super init])) {
        _calls = [NSMutableDictionary dictionary];
        _chats = [NSMutableArray array];
        _byKey = [NSMutableDictionary dictionary];
        _users = [NSMutableDictionary dictionary];
        _chatInfo = [NSMutableDictionary dictionary];
        _dc = 2;
        ACStore *st = [ACStore shared];
        _phone = [st objectForKey:@"tg.phone"];
        _userName = [st objectForKey:@"tg.name"];
        _uid = [[st objectForKey:@"tg.uid"] longLongValue];
        _authorized = [[st objectForKey:@"tg.authorized"] boolValue] && [[st objectForKey:@"tg.key"] length] == 256;
        if (_authorized) {
            _state = ACTGStateReady;
            _dc = [[st objectForKey:@"tg.dc"] intValue];
            if (_dc < 1 || _dc > 5) _dc = 2;
        }
    }
    return self;
}

/* ---------- własności ---------- */

- (BOOL)live { return _authorized; }
- (BOOL)online { return _connOK; }

- (BOOL)builtInKeys { return AC_TG_API_ID > 0 && strlen(AC_TG_API_HASH) >= 16; }
- (int)apiId { return self.builtInKeys ? AC_TG_API_ID : [[[ACStore shared] objectForKey:@"tg.apiId"] intValue]; }
- (NSString *)apiHash
{
    if (self.builtInKeys) return [NSString stringWithUTF8String:AC_TG_API_HASH];
    NSString *h = [[ACStore shared] objectForKey:@"tg.apiHash"];
    return h ? h : @"";
}
- (BOOL)hasCredentials { return self.apiId > 0 && [self.apiHash length] >= 8; }

- (void)saveApiId:(int)apiId apiHash:(NSString *)apiHash
{
    ACStore *st = [ACStore shared];
    [st setObject:[NSNumber numberWithInt:apiId] forKey:@"tg.apiId"];
    [st setObject:apiHash forKey:@"tg.apiHash"];
}

- (NSString *)statusText
{
    if (!_authorized) return nil;
    if (!_connOK) return @"Łączenie…";
    if (_syncing) return @"Aktualizowanie…";
    return nil;
}

- (void)notifyState
{
    [[NSNotificationCenter defaultCenter] postNotificationName:ACTGStateDidChangeNotification object:self];
}

- (void)notifyChats:(ACChat *)chat
{
    NSDictionary *info = chat ? [NSDictionary dictionaryWithObject:chat forKey:@"chat"] : nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:ACTGChatsDidChangeNotification object:self userInfo:info];
}

- (void)setError:(NSString *)e busy:(BOOL)b state:(ACTGState)s
{
    _lastError = e;
    _busy = b;
    _state = s;
    [self notifyState];
}

/* ---------- schemat TL ---------- */

- (tl_schema *)schema
{
    @synchronized(self) {
        if (_schema) return _schema;
        NSString *path = [[NSBundle mainBundle] pathForResource:@"api" ofType:@"tl"];
        NSData *d = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (!d) return NULL;
        _schema = tl_schema_load((const char *)[d bytes], [d length]);
        return _schema;
    }
}

- (int)layer
{
    tl_schema *s = [self schema];
    int l = s ? tl_schema_layer(s) : 0;
    return l > 0 ? l : TG_LAYER_FALLBACK;
}

/* JSON -> binarny TL */
- (NSData *)encode:(NSDictionary *)obj error:(NSString **)err
{
    tl_schema *s = [self schema];
    if (!s) { if (err) *err = @"Brak pliku api.tl w aplikacji."; return nil; }
    NSError *je = nil;
    NSData *jd = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&je];
    if (!jd) { if (err) *err = @"Nie można zbudować zapytania."; return nil; }
    NSMutableData *z = [NSMutableData dataWithData:jd];
    uint8_t zero = 0;
    [z appendBytes:&zero length:1];
    uint8_t *out = NULL;
    size_t olen = 0;
    char e[200];
    if (tl_write_json(s, (const char *)[z bytes], &out, &olen, e, sizeof(e)) != 0) {
        if (err) *err = [NSString stringWithFormat:@"TL: %s", e];
        return nil;
    }
    NSData *r = [NSData dataWithBytes:out length:olen];
    free(out);
    return r;
}

/* binarny TL -> obiekt JSON (NSDictionary / NSArray) */
- (id)decode:(NSData *)d function:(NSString *)fn
{
    tl_schema *s = [self schema];
    if (!s) return nil;
    char *js = NULL;
    size_t used = 0;
    char e[200];
    int r = -1;
    if (fn) r = tl_read_result_json(s, [fn UTF8String], (const uint8_t *)[d bytes], [d length], &js, &used, e, sizeof(e));
    if (r != 0) r = tl_read_json(s, (const uint8_t *)[d bytes], [d length], &js, &used, e, sizeof(e));
    if (r != 0 || !js) return nil;
    NSData *jd = [NSData dataWithBytesNoCopy:js length:strlen(js) freeWhenDone:YES];
    return [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingAllowFragments error:nil];
}

/* ---------- połączenie ---------- */

static NSString *DCFallbackIP(int dc)
{
    switch (dc) {
        case 1: return @"149.154.175.53";
        case 3: return @"149.154.175.100";
        case 4: return @"149.154.167.91";
        case 5: return @"91.108.56.130";
        default: return @"149.154.167.51";
    }
}

- (NSString *)ipForDC:(int)dc
{
    NSDictionary *m = [[ACStore shared] objectForKey:@"tg.dcips"];
    NSString *ip = [m objectForKey:[NSString stringWithFormat:@"%d", dc]];
    return [ip length] ? ip : DCFallbackIP(dc);
}

- (void)failAllCalls:(NSString *)why
{
    NSArray *all;
    @synchronized(self) {
        all = [_calls allValues];
        [_calls removeAllObjects];
    }
    for (ACTGCall *c in all) {
        ACTGDone d = c.done;
        if (d) dispatch_async(dispatch_get_main_queue(), ^{ d(nil, why, -1); });
    }
}

- (void)closeConnection
{
    [self mediaSessionEnded];
    @synchronized(self) {
        _gen++;
        if (_conn) tg_conn_close(_conn);
        _connOK = NO;
    }
    [self failAllCalls:@"Połączenie zamknięte."];
}

- (void)runConn:(NSValue *)v
{
    tg_conn *c = (tg_conn *)[v pointerValue];
    tg_conn_run(c);
    @synchronized(self) {
        if (_conn == c) { _conn = NULL; _connOK = NO; }
    }
    tg_conn_free(c);
}

/* Łączy się z DC. useSaved: użyj zapisanego klucza (jeśli jest dla tego DC), inaczej nowa wymiana kluczy. */
- (void)connectDC:(int)dc useSaved:(BOOL)useSaved done:(void (^)(NSString *err))done
{
    if (_connecting) { if (done) done(@"Łączenie już trwa."); return; }
    _connecting = YES;
    [self closeConnection];
    int gen;
    @synchronized(self) { gen = _gen; }
    ACStore *st = [ACStore shared];
    NSData *savedKey = nil;
    unsigned long long savedSalt = 0;
    int savedOff = 0;
    if (useSaved && [[st objectForKey:@"tg.dc"] intValue] == dc && [[st objectForKey:@"tg.key"] length] == 256) {
        savedKey = [st objectForKey:@"tg.key"];
        savedSalt = [[st objectForKey:@"tg.salt"] unsignedLongLongValue];
        savedOff = [[st objectForKey:@"tg.off"] intValue];
    }
    NSString *ip = [self ipForDC:dc];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        tg_events ev;
        memset(&ev, 0, sizeof(ev));
        ev.ud = (void *)(intptr_t)gen;
        ev.on_result = cbResult;
        ev.on_error = cbError;
        ev.on_update = cbUpdate;
        ev.on_closed = cbClosed;
        tg_conn *c = tg_conn_new(&ev);
        char err[200];
        err[0] = 0;
        NSString *failure = nil;
        if (!c) failure = @"Brak pamięci.";
        else if (tg_conn_open(c, [ip UTF8String], 443, 10000, err, sizeof(err)) != 0) failure = [NSString stringWithFormat:@"Nie można połączyć z Telegramem (%s).", err];
        else if (savedKey) tg_conn_set_auth(c, (const uint8_t *)[savedKey bytes], (uint64_t)savedSalt, (int32_t)savedOff);
        else if (tg_conn_handshake(c, err, sizeof(err)) != 0) failure = [NSString stringWithFormat:@"Wymiana kluczy nie powiodła się: %s", err];
        if (failure) {
            if (c) tg_conn_free(c);
            dispatch_async(dispatch_get_main_queue(), ^{ _connecting = NO; if (done) done(failure); });
            return;
        }
        uint8_t key[256];
        uint64_t salt = 0;
        int32_t off = 0;
        BOOL have = tg_conn_get_auth(c, key, &salt, &off) != 0;
        NSData *keyData = [NSData dataWithBytes:key length:256];
        @synchronized(self) {
            _conn = c;
            _connOK = YES;
            _needInit = YES;
        }
        NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(runConn:) object:[NSValue valueWithPointer:c]];
        [t setStackSize:1024 * 1024];
        [t start];
        dispatch_async(dispatch_get_main_queue(), ^{
            _connecting = NO;
            _dc = dc;
            if (have && !savedKey) {
                ACStore *s2 = [ACStore shared];
                [s2 setObject:keyData forKey:@"tg.key"];
                [s2 setObject:[NSNumber numberWithUnsignedLongLong:salt] forKey:@"tg.salt"];
                [s2 setObject:[NSNumber numberWithInt:off] forKey:@"tg.off"];
                [s2 setObject:[NSNumber numberWithInt:dc] forKey:@"tg.dc"];
            }
            [self notifyState];
            if (done) done(nil);
        });
    });
}

- (void)ensureConnected:(void (^)(NSString *err))done
{
    if (_connOK) { done(nil); return; }
    [self connectDC:_dc useSaved:YES done:done];
}

- (void)connectionClosed:(NSString *)why gen:(int)gen
{
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) { if (gen != _gen) return; }
        _connOK = NO;
        [self failAllCalls:why];
        [self notifyState];
        if (_authorized && !_userClosed) [self scheduleReconnect];
    });
}

- (void)scheduleReconnect
{
    if (_connecting) return;
    int delay = 2 + 3 * (_retry < 8 ? _retry : 8);
    _retry++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (_authorized && !_connOK && !_connecting) [self reconnectNow];
    });
}

- (void)reconnectNow
{
    if (!_authorized || _connecting || _connOK) return;
    [self notifyState];
    [self connectDC:_dc useSaved:YES done:^(NSString *err) {
        if (err) { [self scheduleReconnect]; return; }
        _retry = 0;
        [self afterConnected];
    }];
}

- (void)enteredBackground
{
    /* iOS i tak ubije gniazdo w uśpieniu; zamykamy je same, a po powrocie łączymy od nowa */
    if (_authorized && !_busy && ![[ACCall shared] inProgress]) { _userClosed = YES; [self closeConnection]; [self notifyState]; }
}

- (void)appBecameActive
{
    _userClosed = NO;
    if (_authorized && !_connOK && !_connecting) { _retry = 0; [self reconnectNow]; }
}

- (void)resume
{
    if (_authorized) {
        _userClosed = NO;
        _state = ACTGStateReady;
        [self notifyState];
        [self reconnectNow];
    }
}

/* ---------- zapytania ---------- */

- (NSDictionary *)wrapInit:(NSDictionary *)obj
{
    UIDevice *dev = [UIDevice currentDevice];
    NSDictionary *init = [NSDictionary dictionaryWithObjectsAndKeys:
        @"initConnection", @"_",
        [NSNumber numberWithInt:self.apiId], @"api_id",
        [dev model], @"device_model",
        [dev systemVersion], @"system_version",
        @"0.6.1", @"app_version",
        @"pl", @"system_lang_code",
        @"", @"lang_pack",
        @"pl", @"lang_code",
        obj, @"query", nil];
    return [NSDictionary dictionaryWithObjectsAndKeys:@"invokeWithLayer", @"_", [NSNumber numberWithInt:[self layer]], @"layer", init, @"query", nil];
}

- (int)homeDC { return _dc; }
- (long long)myUserId { return _uid; }
- (NSDictionary *)cachedUser:(long long)uid { return [_users objectForKey:[NSNumber numberWithLongLong:uid]]; }
- (BOOL)connectedHome { return _connOK; }

- (void)call:(NSDictionary *)obj done:(ACTGDone)done { [self call:obj raw:NO done:done]; }
- (void)callRaw:(NSDictionary *)obj done:(ACTGDone)done { [self call:obj raw:YES done:done]; }

- (void)call:(NSDictionary *)obj raw:(BOOL)raw done:(ACTGDone)done
{
    NSString *fn = [obj objectForKey:@"_"];
    NSString *fail = nil;
    int failCode = -1;
    @synchronized(self) {
        if (!_conn || !_connOK) {
            fail = @"Brak połączenia z Telegramem.";
        } else {
            NSDictionary *send = obj;
            BOOL wrapped = NO;
            if (_needInit) {
                send = [self wrapInit:obj];
                wrapped = YES;
            }
            NSString *encErr = nil;
            NSData *bin = [self encode:send error:&encErr];
            if (!bin) { fail = encErr; failCode = -2; }
            else {
                uint32_t tok = tg_conn_request(_conn, (const uint8_t *)[bin bytes], [bin length]);
                if (!tok) fail = @"Nie udało się wysłać zapytania.";
                else {
                    if (wrapped) _needInit = NO;
                    ACTGCall *c = [[ACTGCall alloc] init];
                    c.fn = fn;
                    c.done = done;
                    c.raw = raw;
                    [_calls setObject:c forKey:[NSNumber numberWithUnsignedInt:tok]];
                }
            }
        }
    }
    if (fail && done) done(nil, fail, failCode);
}

- (void)deliverResult:(NSData *)d token:(uint32_t)tok gen:(int)gen
{
    ACTGCall *c;
    @synchronized(self) {
        if (gen != _gen) return;
        NSNumber *k = [NSNumber numberWithUnsignedInt:tok];
        c = [_calls objectForKey:k];
        [_calls removeObjectForKey:k];
    }
    if (!c) return;
    if (c.raw) {
        ACTGDone rd = c.done;
        dispatch_async(dispatch_get_main_queue(), ^{ if (rd) rd(d, nil, 0); });
        return;
    }
    id json = [self decode:d function:c.fn];
    ACTGDone done = c.done;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!done) return;
        if (json) done(json, nil, 0); else done(nil, @"Nie można odczytać odpowiedzi serwera.", -3);
    });
}

- (void)deliverError:(uint32_t)tok code:(int)code message:(NSString *)msg gen:(int)gen
{
    ACTGCall *c;
    @synchronized(self) {
        if (gen != _gen) return;
        NSNumber *k = [NSNumber numberWithUnsignedInt:tok];
        c = [_calls objectForKey:k];
        [_calls removeObjectForKey:k];
    }
    ACTGDone done = c.done;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_authorized && code == 401 && ![msg isEqualToString:@"SESSION_PASSWORD_NEEDED"]) { [self sessionLost:msg]; return; }
        if (done) done(nil, msg, code);
    });
}

- (void)deliverUpdate:(NSData *)d gen:(int)gen
{
    @synchronized(self) { if (gen != _gen) return; }
    id json = [self decode:d function:nil];
    if (!json) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self processUpdates:json]; });
}

- (void)sessionLost:(NSString *)msg
{
    [self wipeSession];
    [self setError:PLError(401, msg) busy:NO state:ACTGStateOffline];
    [self notifyChats:nil];
}

/* ---------- logowanie ---------- */

- (NSString *)normalizedPhone:(NSString *)p
{
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < [p length]; i++) {
        unichar ch = [p characterAtIndex:i];
        if (ch >= '0' && ch <= '9') [digits appendFormat:@"%C", ch];
    }
    if ([digits hasPrefix:@"00"]) [digits deleteCharactersInRange:NSMakeRange(0, 2)];
    else if ([digits length] == 9) [digits insertString:@"48" atIndex:0];      /* polski numer bez kierunkowego */
    return digits;
}

- (void)startLoginWithPhone:(NSString *)phone
{
    if (_busy) return;
    if (!self.hasCredentials) { [self setError:@"Najpierw podaj api_id i api_hash." busy:NO state:ACTGStateOffline]; return; }
    NSString *p = [self normalizedPhone:phone];
    if ([p length] < 8) { [self setError:@"Podaj numer telefonu z numerem kraju." busy:NO state:ACTGStateOffline]; return; }
    _phone = p;
    [[ACStore shared] setObject:p forKey:@"tg.phone"];
    _userClosed = NO;
    [self setError:nil busy:YES state:ACTGStateConnecting];
    [[ACStore shared] setObject:nil forKey:@"tg.key"];
    [self connectDC:2 useSaved:NO done:^(NSString *err) {
        if (err) { [self setError:err busy:NO state:ACTGStateOffline]; return; }
        [self sendCodeRequest];
    }];
}

- (void)sendCodeRequest
{
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:
        @"auth.sendCode", @"_", _phone, @"phone_number",
        [NSNumber numberWithInt:self.apiId], @"api_id", self.apiHash, @"api_hash",
        [NSDictionary dictionaryWithObject:@"codeSettings" forKey:@"_"], @"settings", nil];
    [self call:req done:^(id res, NSString *err, int code) {
        if (err) {
            if (code == 303 && [err hasPrefix:@"PHONE_MIGRATE_"]) { [self migrateToDC:[[err substringFromIndex:14] intValue]]; return; }
            [self setError:PLError(code, err) busy:NO state:ACTGStateOffline];
            return;
        }
        [self handleSentCode:res];
    }];
}

- (void)handleSentCode:(id)res
{
    NSDictionary *r = DictOf(res);
    NSString *t = StrOf([r objectForKey:@"_"]);
    if ([t isEqualToString:@"auth.sentCodeSuccess"]) { [self finishAuthorization:DictOf([r objectForKey:@"authorization"])]; return; }
    if (![t isEqualToString:@"auth.sentCode"]) { [self setError:@"Telegram nie wysłał kodu." busy:NO state:ACTGStateOffline]; return; }
    _codeHash = StrOf([r objectForKey:@"phone_code_hash"]);
    NSString *ty = StrOf([DictOf([r objectForKey:@"type"]) objectForKey:@"_"]);
    if ([ty isEqualToString:@"auth.sentCodeTypeApp"]) _codeInfo = @"Kod wysłano w wiadomości do aplikacji Telegram na innym Twoim urządzeniu.";
    else if ([ty isEqualToString:@"auth.sentCodeTypeSms"]) _codeInfo = @"Kod wysłano SMS-em.";
    else if ([ty isEqualToString:@"auth.sentCodeTypeCall"]) _codeInfo = @"Kod zostanie podany w rozmowie telefonicznej.";
    else if ([ty isEqualToString:@"auth.sentCodeTypeFlashCall"] || [ty isEqualToString:@"auth.sentCodeTypeMissedCall"]) _codeInfo = @"Kod to ostatnie cyfry numeru, który do Ciebie zadzwoni.";
    else _codeInfo = @"Kod został wysłany.";
    [self setError:nil busy:NO state:ACTGStateNeedCode];
}

- (void)migrateToDC:(int)dc
{
    if (dc < 1 || dc > 5) { [self setError:@"Nieznane centrum danych Telegrama." busy:NO state:ACTGStateOffline]; return; }
    [self call:[NSDictionary dictionaryWithObject:@"help.getConfig" forKey:@"_"] done:^(id res, NSString *err, int code) {
        NSMutableDictionary *ips = [NSMutableDictionary dictionaryWithDictionary:[[ACStore shared] objectForKey:@"tg.dcips"]];
        for (id o in ArrOf([DictOf(res) objectForKey:@"dc_options"])) {
            NSDictionary *d = DictOf(o);
            if (!d || BoolOf([d objectForKey:@"ipv6"]) || BoolOf([d objectForKey:@"media_only"]) || BoolOf([d objectForKey:@"cdn"]) || BoolOf([d objectForKey:@"tcpo_only"])) continue;
            if (IntOf([d objectForKey:@"port"]) != 443) continue;
            [ips setObject:StrOf([d objectForKey:@"ip_address"]) forKey:[NSString stringWithFormat:@"%d", IntOf([d objectForKey:@"id"])]];
        }
        [[ACStore shared] setObject:ips forKey:@"tg.dcips"];
        [[ACStore shared] setObject:nil forKey:@"tg.key"];
        [self connectDC:dc useSaved:NO done:^(NSString *e2) {
            if (e2) { [self setError:e2 busy:NO state:ACTGStateOffline]; return; }
            [self sendCodeRequest];
        }];
    }];
}

- (void)resendCode
{
    if (_busy || ![_codeHash length]) return;
    [self setError:nil busy:YES state:ACTGStateNeedCode];
    [self ensureConnected:^(NSString *e) {
        if (e) { [self setError:e busy:NO state:ACTGStateNeedCode]; return; }
        NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"auth.resendCode", @"_", _phone, @"phone_number", _codeHash, @"phone_code_hash", nil];
        [self call:req done:^(id res, NSString *err, int code) {
            if (err) { [self setError:PLError(code, err) busy:NO state:ACTGStateNeedCode]; return; }
            [self handleSentCode:res];
        }];
    }];
}

- (void)submitCode:(NSString *)code
{
    if (_busy) return;
    NSString *c = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([c length] == 0) { [self setError:@"Wpisz kod." busy:NO state:ACTGStateNeedCode]; return; }
    [self setError:nil busy:YES state:ACTGStateNeedCode];
    [self ensureConnected:^(NSString *e) {
        if (e) { [self setError:e busy:NO state:ACTGStateNeedCode]; return; }
        NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"auth.signIn", @"_", _phone, @"phone_number", _codeHash, @"phone_code_hash", c, @"phone_code", nil];
        [self call:req done:^(id res, NSString *err, int errCode) {
            if (err) {
                if ([err isEqualToString:@"SESSION_PASSWORD_NEEDED"]) { [self fetchPasswordHint]; return; }
                [self setError:PLError(errCode, err) busy:NO state:ACTGStateNeedCode];
                return;
            }
            [self handleAuth:res fromState:ACTGStateNeedCode];
        }];
    }];
}

- (void)fetchPasswordHint
{
    [self call:[NSDictionary dictionaryWithObject:@"account.getPassword" forKey:@"_"] done:^(id res, NSString *err, int code) {
        _passwordHint = StrOf([DictOf(res) objectForKey:@"hint"]);
        [self setError:nil busy:NO state:ACTGStateNeedPassword];
    }];
}

- (void)handleAuth:(id)res fromState:(ACTGState)from
{
    NSDictionary *r = DictOf(res);
    NSString *t = StrOf([r objectForKey:@"_"]);
    if ([t isEqualToString:@"auth.authorization"]) { [self finishAuthorization:r]; return; }
    if ([t isEqualToString:@"auth.authorizationSignUpRequired"]) {
        [self setError:@"Ten numer nie ma jeszcze konta w Telegramie. Załóż je w oficjalnej aplikacji, potem wróć tutaj." busy:NO state:ACTGStateOffline];
        return;
    }
    [self setError:@"Nieoczekiwana odpowiedź przy logowaniu." busy:NO state:from];
}

- (void)submitPassword:(NSString *)password
{
    if (_busy) return;
    if ([password length] == 0) { [self setError:@"Wpisz hasło." busy:NO state:ACTGStateNeedPassword]; return; }
    [self setError:nil busy:YES state:ACTGStateNeedPassword];
    [self ensureConnected:^(NSString *e) {
        if (e) { [self setError:e busy:NO state:ACTGStateNeedPassword]; return; }
        [self call:[NSDictionary dictionaryWithObject:@"account.getPassword" forKey:@"_"] done:^(id res, NSString *err, int code) {
            if (err) { [self setError:PLError(code, err) busy:NO state:ACTGStateNeedPassword]; return; }
            NSDictionary *pw = DictOf(res);
            NSDictionary *algo = DictOf([pw objectForKey:@"current_algo"]);
            if (!algo || ![StrOf([algo objectForKey:@"_"]) hasPrefix:@"passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000"]) {
                [self setError:@"Nieobsługiwany typ hasła na koncie." busy:NO state:ACTGStateNeedPassword];
                return;
            }
            NSData *s1 = UnHex(StrOf([algo objectForKey:@"salt1"])), *s2 = UnHex(StrOf([algo objectForKey:@"salt2"]));
            NSData *p = UnHex(StrOf([algo objectForKey:@"p"])), *B = UnHex(StrOf([pw objectForKey:@"srp_B"]));
            int g = IntOf([algo objectForKey:@"g"]);
            long long srpIdValue = LongOf([pw objectForKey:@"srp_id"]);
            NSData *pwd = [password dataUsingEncoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                uint8_t rnd[256], A[256], M1[32];
                tg_random(rnd, 256);
                int r = -9;
                if ([p length] == 256) {
                    r = tg_srp_check((const uint8_t *)[s1 bytes], [s1 length], (const uint8_t *)[s2 bytes], [s2 length], g,
                                     (const uint8_t *)[p bytes], (const uint8_t *)[B bytes], [B length],
                                     (const uint8_t *)[pwd bytes], [pwd length], rnd, A, M1);
                }
                NSData *aData = [NSData dataWithBytes:A length:256], *mData = [NSData dataWithBytes:M1 length:32];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (r != 0) { [self setError:@"Serwer przysłał niepoprawne parametry hasła." busy:NO state:ACTGStateNeedPassword]; return; }
                    NSDictionary *chk = [NSDictionary dictionaryWithObjectsAndKeys:@"inputCheckPasswordSRP", @"_", LS(srpIdValue), @"srp_id",
                                         Hex(aData), @"A", Hex(mData), @"M1", nil];
                    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"auth.checkPassword", @"_", chk, @"password", nil];
                    [self call:req done:^(id res2, NSString *err2, int code2) {
                        if (err2) { [self setError:PLError(code2, err2) busy:NO state:ACTGStateNeedPassword]; return; }
                        [self handleAuth:res2 fromState:ACTGStateNeedPassword];
                    }];
                });
            });
        }];
    }];
}

- (void)cancelLogin
{
    if (_authorized) return;
    [self closeConnection];
    _codeHash = nil;
    [self setError:nil busy:NO state:ACTGStateOffline];
}

- (NSString *)displayNameOfUser:(NSDictionary *)u
{
    NSString *f = StrOf([u objectForKey:@"first_name"]), *l = StrOf([u objectForKey:@"last_name"]);
    NSString *n = [l length] ? [NSString stringWithFormat:@"%@ %@", f, l] : f;
    if ([n length] == 0) n = StrOf([u objectForKey:@"username"]);
    return n;
}

- (void)finishAuthorization:(NSDictionary *)auth
{
    NSDictionary *u = DictOf([auth objectForKey:@"user"]);
    _uid = LongOf([u objectForKey:@"id"]);
    _userName = [self displayNameOfUser:u];
    if (u) [_users setObject:u forKey:[NSNumber numberWithLongLong:_uid]];
    ACStore *st = [ACStore shared];
    [st setObject:[NSNumber numberWithLongLong:_uid] forKey:@"tg.uid"];
    [st setObject:_userName ? _userName : @"" forKey:@"tg.name"];
    [st setObject:[NSNumber numberWithBool:YES] forKey:@"tg.authorized"];
    [st setObject:[NSNumber numberWithInt:_dc] forKey:@"tg.dc"];
    _authorized = YES;
    _retry = 0;
    [_chats removeAllObjects];
    [_byKey removeAllObjects];
    [self setError:nil busy:NO state:ACTGStateReady];
    [self notifyChats:nil];
    [self afterConnected];
}

- (void)wipeSession
{
    [[ACCall shared] sessionEnded];
    [self closeConnection];
    [self mediaWipe];
    _authorized = NO;
    _codeHash = nil;
    ACStore *st = [ACStore shared];
    for (NSString *k in [NSArray arrayWithObjects:@"tg.key", @"tg.salt", @"tg.off", @"tg.authorized", @"tg.uid", @"tg.name", nil]) [st setObject:nil forKey:k];
    _userName = nil;
    [_chats removeAllObjects];
    [_byKey removeAllObjects];
    [_users removeAllObjects];
    [_chatInfo removeAllObjects];
}

- (void)logOut
{
    _userClosed = YES;
    void (^finish)(void) = ^{
        [self wipeSession];
        [self setError:nil busy:NO state:ACTGStateOffline];
        [self notifyChats:nil];
    };
    if (_connOK) {
        __block BOOL done = NO;
        [self call:[NSDictionary dictionaryWithObject:@"auth.logOut" forKey:@"_"] done:^(id r, NSString *e, int c) { if (!done) { done = YES; finish(); } }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!done) { done = YES; finish(); } });
    } else finish();
}

/* ---------- po połączeniu: stan, dialogi ---------- */

- (void)afterConnected
{
    [self notifyState];
    [self call:[NSDictionary dictionaryWithObject:@"updates.getState" forKey:@"_"] done:^(id r, NSString *e, int c) {}];
    [self reloadDialogs];
}

/* ---------- encje ---------- */

- (void)cacheEntities:(NSDictionary *)r
{
    for (id o in ArrOf([r objectForKey:@"users"])) {
        NSDictionary *u = DictOf(o);
        if (!u) continue;
        NSNumber *k = [NSNumber numberWithLongLong:LongOf([u objectForKey:@"id"])];
        NSDictionary *old = [_users objectForKey:k];
        /* "min" nie ma access_hash: nie nadpisuj pełnego wpisu */
        if (old && ![u objectForKey:@"access_hash"] && [old objectForKey:@"access_hash"]) continue;
        [_users setObject:u forKey:k];
    }
    for (id o in ArrOf([r objectForKey:@"chats"])) {
        NSDictionary *c = DictOf(o);
        if (!c) continue;
        NSString *t = StrOf([c objectForKey:@"_"]);
        BOOL ch = [t hasPrefix:@"channel"];
        NSString *k = [NSString stringWithFormat:@"%@%lld", ch ? @"h" : @"c", LongOf([c objectForKey:@"id"])];
        NSDictionary *old = [_chatInfo objectForKey:k];
        if (old && ![c objectForKey:@"access_hash"] && [old objectForKey:@"access_hash"]) continue;
        [_chatInfo setObject:c forKey:k];
    }
}

- (NSString *)keyForPeer:(NSDictionary *)p kind:(int *)kind id:(long long *)pid
{
    NSString *t = StrOf([p objectForKey:@"_"]);
    if ([t isEqualToString:@"peerUser"]) { *kind = 1; *pid = LongOf([p objectForKey:@"user_id"]); return [NSString stringWithFormat:@"u%lld", *pid]; }
    if ([t isEqualToString:@"peerChat"]) { *kind = 2; *pid = LongOf([p objectForKey:@"chat_id"]); return [NSString stringWithFormat:@"c%lld", *pid]; }
    if ([t isEqualToString:@"peerChannel"]) { *kind = 3; *pid = LongOf([p objectForKey:@"channel_id"]); return [NSString stringWithFormat:@"h%lld", *pid]; }
    return nil;
}

- (NSString *)statusOfUser:(NSDictionary *)u
{
    if (BoolOf([u objectForKey:@"bot"])) return @"bot";
    if (BoolOf([u objectForKey:@"deleted"])) return @"";
    NSDictionary *s = DictOf([u objectForKey:@"status"]);
    NSString *t = StrOf([s objectForKey:@"_"]);
    if ([t isEqualToString:@"userStatusOnline"]) return @"online";
    if ([t isEqualToString:@"userStatusOffline"]) return WasOnline(IntOf([s objectForKey:@"was_online"]));
    if ([t isEqualToString:@"userStatusRecently"]) return @"był(a) niedawno";
    if ([t isEqualToString:@"userStatusLastWeek"]) return @"był(a) w zeszłym tygodniu";
    if ([t isEqualToString:@"userStatusLastMonth"]) return @"był(a) w zeszłym miesiącu";
    return @"był(a) dawno temu";
}

/* uzupełnia nazwę, status i hash dostępu z pamięci podręcznej */
- (void)refreshChat:(ACChat *)c
{
    if (c.peerKind == 1) {
        NSDictionary *u = [_users objectForKey:[NSNumber numberWithLongLong:c.peerId]];
        if (c.peerId == _uid) { c.name = @"Zapisane wiadomości"; c.status = @"chmura Telegrama"; }
        else if (u) {
            NSString *n = [self displayNameOfUser:u];
            c.name = BoolOf([u objectForKey:@"deleted"]) ? @"Usunięte konto" : ([n length] ? n : @"Użytkownik");
            c.status = [self statusOfUser:u];
        } else if (![c.name length]) c.name = @"Użytkownik";
        if ([u objectForKey:@"access_hash"]) c.accessHash = LongOf([u objectForKey:@"access_hash"]);
        c.isGroup = NO;
        c.canWrite = YES;
    } else {
        NSString *k = [NSString stringWithFormat:@"%@%lld", c.peerKind == 3 ? @"h" : @"c", c.peerId];
        NSDictionary *ci = [_chatInfo objectForKey:k];
        if (ci) {
            NSString *title = StrOf([ci objectForKey:@"title"]);
            c.name = [title length] ? title : @"Czat";
            if ([ci objectForKey:@"access_hash"]) c.accessHash = LongOf([ci objectForKey:@"access_hash"]);
            if (c.peerKind == 3) {
                BOOL mega = BoolOf([ci objectForKey:@"megagroup"]);
                c.isGroup = mega;
                c.status = mega ? @"grupa" : @"kanał";
                c.canWrite = mega || BoolOf([ci objectForKey:@"creator"]);
            } else {
                c.isGroup = YES;
                int n = IntOf([ci objectForKey:@"participants_count"]);
                c.status = n > 0 ? [NSString stringWithFormat:@"grupa, uczestników: %d", n] : @"grupa";
                c.canWrite = YES;
            }
        } else if (![c.name length]) c.name = @"Czat";
    }
}

- (NSDictionary *)inputPeerFor:(ACChat *)c
{
    if (c.peerKind == 1) {
        if (c.peerId == _uid) return [NSDictionary dictionaryWithObject:@"inputPeerSelf" forKey:@"_"];
        return [NSDictionary dictionaryWithObjectsAndKeys:@"inputPeerUser", @"_", LS(c.peerId), @"user_id", LS(c.accessHash), @"access_hash", nil];
    }
    if (c.peerKind == 2) return [NSDictionary dictionaryWithObjectsAndKeys:@"inputPeerChat", @"_", LS(c.peerId), @"chat_id", nil];
    return [NSDictionary dictionaryWithObjectsAndKeys:@"inputPeerChannel", @"_", LS(c.peerId), @"channel_id", LS(c.accessHash), @"access_hash", nil];
}

- (ACChat *)chatForPeer:(NSDictionary *)peer create:(BOOL)create
{
    int kind = 0;
    long long pid = 0;
    NSString *k = [self keyForPeer:peer kind:&kind id:&pid];
    if (!k) return nil;
    ACChat *c = [_byKey objectForKey:k];
    if (!c && create) {
        c = [[ACChat alloc] init];
        c.peerKind = kind;
        c.peerId = pid;
        [_byKey setObject:c forKey:k];
        [_chats addObject:c];
    }
    if (c) [self refreshChat:c];
    return c;
}

/* ---------- wiadomości ---------- */

- (NSString *)senderNameOf:(NSDictionary *)m
{
    NSDictionary *from = DictOf([m objectForKey:@"from_id"]);
    if (![StrOf([from objectForKey:@"_"]) isEqualToString:@"peerUser"]) return @"";
    NSDictionary *u = [_users objectForKey:[NSNumber numberWithLongLong:LongOf([from objectForKey:@"user_id"])]];
    NSString *f = StrOf([u objectForKey:@"first_name"]);
    return [f length] ? f : StrOf([u objectForKey:@"username"]);
}

static NSString *MediaLabel(NSDictionary *media)
{
    NSString *t = StrOf([media objectForKey:@"_"]);
    if ([t isEqualToString:@"messageMediaPhoto"]) return @"[Zdjęcie]";
    if ([t isEqualToString:@"messageMediaDocument"]) {
        if (BoolOf([media objectForKey:@"voice"])) return @"[Wiadomość głosowa]";
        if (BoolOf([media objectForKey:@"round"])) return @"[Wideo-wiadomość]";
        if (BoolOf([media objectForKey:@"video"])) return @"[Wideo]";
        return @"[Plik]";
    }
    if ([t isEqualToString:@"messageMediaGeo"] || [t isEqualToString:@"messageMediaGeoLive"] || [t isEqualToString:@"messageMediaVenue"]) return @"[Lokalizacja]";
    if ([t isEqualToString:@"messageMediaContact"]) return @"[Kontakt]";
    if ([t isEqualToString:@"messageMediaPoll"]) return @"[Ankieta]";
    if ([t isEqualToString:@"messageMediaWebPage"]) return @"";
    return @"[Załącznik]";
}

static NSString *ServiceLabel(NSDictionary *action, BOOL out)
{
    if ([StrOf([action objectForKey:@"_"]) isEqualToString:@"messageActionPhoneCall"]) {
        NSString *rs = StrOf([DictOf([action objectForKey:@"reason"]) objectForKey:@"_"]);
        NSString *kind = BoolOf([action objectForKey:@"video"]) ? @"Wideorozmowa" : @"Rozmowa głosowa";
        if ([rs isEqualToString:@"phoneCallDiscardReasonMissed"]) return out ? @"[Rozmowa bez odpowiedzi]" : @"[Nieodebrana rozmowa]";
        if ([rs isEqualToString:@"phoneCallDiscardReasonBusy"]) return @"[Rozmówca był zajęty]";
        int d = IntOf([action objectForKey:@"duration"]);
        if (d > 0) return [NSString stringWithFormat:@"[%@, %d:%02d]", kind, d / 60, d % 60];
        return [NSString stringWithFormat:@"[%@]", kind];
    }
    return @"[wiadomość serwisowa]";
}

- (ACMessage *)messageFrom:(NSDictionary *)m chat:(ACChat *)chat
{
    NSString *t = StrOf([m objectForKey:@"_"]);
    ACMessage *am = [[ACMessage alloc] init];
    am.msgId = IntOf([m objectForKey:@"id"]);
    am.date = IntOf([m objectForKey:@"date"]);
    am.outgoing = BoolOf([m objectForKey:@"out"]);
    am.time = TimeString(am.date);
    NSString *text;
    if ([t isEqualToString:@"messageService"]) text = ServiceLabel(DictOf([m objectForKey:@"action"]), am.outgoing);
    else {
        text = StrOf([m objectForKey:@"message"]);
        NSDictionary *md = DictOf([m objectForKey:@"media"]);
        ACMedia *media = [ACMedia mediaFromJSON:md];
        if (media) {
            media.msgId = am.msgId;
            media.peerKind = chat.peerKind;
            media.peerId = chat.peerId;
            media.peerAccess = chat.accessHash;
            am.media = media;                     /* tekst to tylko podpis */
        } else {
            NSString *ml = MediaLabel(md);
            if ([ml length]) text = [text length] ? [NSString stringWithFormat:@"%@ %@", ml, text] : ml;
            if ([text length] == 0) text = @"[wiadomość]";
        }
    }
    if (chat.isGroup && !am.outgoing && ![t isEqualToString:@"messageService"]) {
        NSString *sn = [self senderNameOf:m];
        if ([sn length]) am.sender = sn;
    }
    am.text = text;
    return am;
}

- (void)sortChats
{
    [_chats sortUsingComparator:^NSComparisonResult(ACChat *a, ACChat *b) {
        if (a.lastDate == b.lastDate) return NSOrderedSame;
        return a.lastDate > b.lastDate ? NSOrderedAscending : NSOrderedDescending;
    }];
}

/* dodaje wiadomość do czatu (bez duplikatów); zwraca YES, jeśli dodano */
- (BOOL)appendMessage:(ACMessage *)m toChat:(ACChat *)chat
{
    if (m.msgId != 0) {
        for (NSInteger i = (NSInteger)[chat.messages count] - 1; i >= 0 && i >= (NSInteger)[chat.messages count] - 80; i--) {
            if (((ACMessage *)[chat.messages objectAtIndex:(NSUInteger)i]).msgId == m.msgId) return NO;
        }
    }
    [chat.messages addObject:m];
    if (m.date > chat.lastDate) chat.lastDate = m.date;
    return YES;
}

/* ---------- dialogi ---------- */

- (void)reloadDialogs
{
    if (!_authorized || !_connOK) return;
    _syncing = YES;
    [self notifyState];
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"messages.getDialogs", @"_",
        [NSNumber numberWithInt:0], @"offset_date", [NSNumber numberWithInt:0], @"offset_id",
        [NSDictionary dictionaryWithObject:@"inputPeerEmpty" forKey:@"_"], @"offset_peer",
        [NSNumber numberWithInt:60], @"limit", [NSNumber numberWithInt:0], @"hash", nil];
    [self call:req done:^(id res, NSString *err, int code) {
        _syncing = NO;
        if (err) { [self notifyState]; return; }
        NSDictionary *r = DictOf(res);
        [self cacheEntities:r];
        NSMutableDictionary *msgs = [NSMutableDictionary dictionary];
        for (id o in ArrOf([r objectForKey:@"messages"])) {
            NSDictionary *m = DictOf(o);
            int kind = 0; long long pid = 0;
            NSString *k = [self keyForPeer:DictOf([m objectForKey:@"peer_id"]) kind:&kind id:&pid];
            if (k) [msgs setObject:m forKey:[NSString stringWithFormat:@"%@:%d", k, IntOf([m objectForKey:@"id"])]];
        }
        NSMutableArray *fresh = [NSMutableArray array];
        for (id o in ArrOf([r objectForKey:@"dialogs"])) {
            NSDictionary *d = DictOf(o);
            if (![StrOf([d objectForKey:@"_"]) isEqualToString:@"dialog"]) continue;
            int kind = 0; long long pid = 0;
            NSString *k = [self keyForPeer:DictOf([d objectForKey:@"peer"]) kind:&kind id:&pid];
            if (!k) continue;
            ACChat *c = [_byKey objectForKey:k];
            if (!c) { c = [[ACChat alloc] init]; c.peerKind = kind; c.peerId = pid; [_byKey setObject:c forKey:k]; }
            [self refreshChat:c];
            c.unread = IntOf([d objectForKey:@"unread_count"]);
            NSDictionary *top = [msgs objectForKey:[NSString stringWithFormat:@"%@:%d", k, IntOf([d objectForKey:@"top_message"])]];
            if (top) {
                ACMessage *am = [self messageFrom:top chat:c];
                if (!c.historyLoaded) { [c.messages removeAllObjects]; [c.messages addObject:am]; if (am.date > c.lastDate) c.lastDate = am.date; }
                else [self appendMessage:am toChat:c];
                c.lastDate = am.date > c.lastDate ? am.date : c.lastDate;
            }
            [fresh addObject:c];
        }
        /* czaty spoza odpowiedzi znikają z listy */
        for (ACChat *c in [NSArray arrayWithArray:_chats]) if (![fresh containsObject:c]) {
            NSString *k = [NSString stringWithFormat:@"%@%lld", c.peerKind == 1 ? @"u" : (c.peerKind == 2 ? @"c" : @"h"), c.peerId];
            [_byKey removeObjectForKey:k];
        }
        [_chats setArray:fresh];
        [self sortChats];
        [self notifyState];
        [self notifyChats:nil];
    }];
}

- (void)loadHistoryForChat:(ACChat *)chat
{
    if (!_authorized || chat.peerKind == 0 || chat.loadingHistory || !_connOK) return;
    chat.loadingHistory = YES;
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"messages.getHistory", @"_", [self inputPeerFor:chat], @"peer",
        [NSNumber numberWithInt:0], @"offset_id", [NSNumber numberWithInt:0], @"offset_date", [NSNumber numberWithInt:0], @"add_offset",
        [NSNumber numberWithInt:50], @"limit", [NSNumber numberWithInt:0], @"max_id", [NSNumber numberWithInt:0], @"min_id", [NSNumber numberWithInt:0], @"hash", nil];
    [self call:req done:^(id res, NSString *err, int code) {
        chat.loadingHistory = NO;
        if (err) { [self notifyChats:chat]; return; }
        NSDictionary *r = DictOf(res);
        [self cacheEntities:r];
        [self refreshChat:chat];
        NSMutableArray *list = [NSMutableArray array];
        NSArray *raw = ArrOf([r objectForKey:@"messages"]);
        for (NSInteger i = (NSInteger)[raw count] - 1; i >= 0; i--) {      /* serwer daje od najnowszej */
            NSDictionary *m = DictOf([raw objectAtIndex:(NSUInteger)i]);
            if (m) [list addObject:[self messageFrom:m chat:chat]];
        }
        for (ACMessage *m in chat.messages) if (m.msgId == 0) [list addObject:m];      /* jeszcze niewysłane */
        [chat.messages setArray:list];
        chat.historyLoaded = YES;
        ACMessage *last = nil;
        for (ACMessage *m in chat.messages) if (m.date > 0) last = m;
        if (last && last.date > chat.lastDate) chat.lastDate = last.date;
        [self notifyChats:chat];
    }];
}

- (void)markReadChat:(ACChat *)chat
{
    chat.unread = 0;
    if (!_authorized || !_connOK || chat.peerKind == 0) return;
    int maxId = 0;
    for (ACMessage *m in chat.messages) if (m.msgId > maxId) maxId = m.msgId;
    if (maxId == 0) return;
    NSDictionary *req;
    if (chat.peerKind == 3) {
        NSDictionary *ch = [NSDictionary dictionaryWithObjectsAndKeys:@"inputChannel", @"_", LS(chat.peerId), @"channel_id", LS(chat.accessHash), @"access_hash", nil];
        req = [NSDictionary dictionaryWithObjectsAndKeys:@"channels.readHistory", @"_", ch, @"channel", [NSNumber numberWithInt:maxId], @"max_id", nil];
    } else {
        req = [NSDictionary dictionaryWithObjectsAndKeys:@"messages.readHistory", @"_", [self inputPeerFor:chat], @"peer", [NSNumber numberWithInt:maxId], @"max_id", nil];
    }
    [self call:req done:^(id r, NSString *e, int c) {}];
}

- (void)sendText:(NSString *)text toChat:(ACChat *)chat
{
    ACMessage *m = [[ACMessage alloc] init];
    m.text = text;
    m.outgoing = YES;
    m.pending = YES;
    m.time = @"wysyłanie…";
    uint8_t rb[8];
    tg_random(rb, 8);
    long long rid = 0;
    memcpy(&rid, rb, 8);
    m.randomId = rid;
    [chat.messages addObject:m];
    [self notifyChats:chat];
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"messages.sendMessage", @"_", [self inputPeerFor:chat], @"peer",
        text, @"message", LS(rid), @"random_id", nil];
    [self call:req done:^(id res, NSString *err, int code) {
        if (err) {
            m.pending = NO;
            m.failed = YES;
            m.time = @"nie wysłano";
            [self notifyChats:chat];
            return;
        }
        NSDictionary *r = DictOf(res);
        NSString *t = StrOf([r objectForKey:@"_"]);
        if ([t isEqualToString:@"updateShortSentMessage"]) {
            m.msgId = IntOf([r objectForKey:@"id"]);
            m.date = IntOf([r objectForKey:@"date"]);
        } else {
            [self processUpdates:r];
        }
        m.pending = NO;
        if (m.date == 0) m.date = (int)time(NULL);
        m.time = TimeString(m.date);
        if (m.date > chat.lastDate) chat.lastDate = m.date;
        [self sortChats];
        [self notifyChats:chat];
    }];
}

/* ---------- aktualizacje ---------- */

- (ACMessage *)pendingMessageWithRandomId:(long long)rid chat:(ACChat **)outChat
{
    for (ACChat *c in _chats) {
        for (NSInteger i = (NSInteger)[c.messages count] - 1; i >= 0; i--) {
            ACMessage *m = [c.messages objectAtIndex:(NSUInteger)i];
            if (m.randomId == rid && rid != 0) { if (outChat) *outChat = c; return m; }
        }
    }
    return nil;
}

- (void)newMessageJSON:(NSDictionary *)m
{
    ACChat *c = [self chatForPeer:DictOf([m objectForKey:@"peer_id"]) create:YES];
    if (!c) return;
    ACMessage *am = [self messageFrom:m chat:c];
    if ([self appendMessage:am toChat:c]) {
        if (!am.outgoing) c.unread++;
        [self sortChats];
        [self notifyChats:c];
    }
}

- (void)processUpdates:(id)json
{
    NSDictionary *u = DictOf(json);
    if (!u) return;
    NSString *t = StrOf([u objectForKey:@"_"]);
    if ([t isEqualToString:@"updates"] || [t isEqualToString:@"updatesCombined"]) {
        [self cacheEntities:u];
        for (id o in ArrOf([u objectForKey:@"updates"])) [self processUpdate:DictOf(o)];
    } else if ([t isEqualToString:@"updateShort"]) {
        [self processUpdate:DictOf([u objectForKey:@"update"])];
    } else if ([t isEqualToString:@"updateShortMessage"] || [t isEqualToString:@"updateShortChatMessage"]) {
        BOOL group = [t isEqualToString:@"updateShortChatMessage"];
        NSDictionary *peer = group ? [NSDictionary dictionaryWithObjectsAndKeys:@"peerChat", @"_", [u objectForKey:@"chat_id"], @"chat_id", nil]
                                   : [NSDictionary dictionaryWithObjectsAndKeys:@"peerUser", @"_", [u objectForKey:@"user_id"], @"user_id", nil];
        ACChat *c = [self chatForPeer:peer create:NO];
        if (!c) { [self reloadDialogs]; return; }
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"message", @"_", [u objectForKey:@"id"], @"id",
            [u objectForKey:@"message"], @"message", [u objectForKey:@"date"], @"date", peer, @"peer_id", nil];
        if (BoolOf([u objectForKey:@"out"])) [m setObject:[NSNumber numberWithBool:YES] forKey:@"out"];
        if (group) [m setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"peerUser", @"_", [u objectForKey:@"from_id"], @"user_id", nil] forKey:@"from_id"];
        [self newMessageJSON:m];
    } else if ([t isEqualToString:@"updatesTooLong"]) {
        [self reloadDialogs];
    } else if ([t isEqualToString:@"updateShortSentMessage"]) {
        /* obsługiwane w sendText */
    } else {
        [self processUpdate:u];
    }
}

- (void)processUpdate:(NSDictionary *)u
{
    NSString *t = StrOf([u objectForKey:@"_"]);
    if ([t isEqualToString:@"updateMessageID"]) {
        ACChat *c = nil;
        ACMessage *m = [self pendingMessageWithRandomId:LongOf([u objectForKey:@"random_id"]) chat:&c];
        if (m) {
            m.msgId = IntOf([u objectForKey:@"id"]);
            if (m.date == 0) m.date = (int)time(NULL);
            m.pending = NO;
            m.time = TimeString(m.date);
            [self notifyChats:c];
        }
    } else if ([t isEqualToString:@"updateNewMessage"] || [t isEqualToString:@"updateNewChannelMessage"]) {
        NSDictionary *m = DictOf([u objectForKey:@"message"]);
        if ([StrOf([m objectForKey:@"_"]) hasPrefix:@"message"]) [self newMessageJSON:m];
    } else if ([t isEqualToString:@"updateReadHistoryInbox"]) {
        ACChat *c = [self chatForPeer:DictOf([u objectForKey:@"peer"]) create:NO];
        if (c) { c.unread = IntOf([u objectForKey:@"still_unread_count"]); [self notifyChats:c]; }
    } else if ([t isEqualToString:@"updateUserStatus"]) {
        long long uid = LongOf([u objectForKey:@"user_id"]);
        NSNumber *k = [NSNumber numberWithLongLong:uid];
        NSMutableDictionary *usr = [NSMutableDictionary dictionaryWithDictionary:[_users objectForKey:k]];
        if ([usr count]) {
            [usr setObject:[u objectForKey:@"status"] forKey:@"status"];
            [_users setObject:usr forKey:k];
            ACChat *c = [_byKey objectForKey:[NSString stringWithFormat:@"u%lld", uid]];
            if (c) { c.status = [self statusOfUser:usr]; [self notifyChats:c]; }
        }
    } else if ([t isEqualToString:@"updateEditMessage"] || [t isEqualToString:@"updateEditChannelMessage"]) {
        NSDictionary *m = DictOf([u objectForKey:@"message"]);
        ACChat *c = [self chatForPeer:DictOf([m objectForKey:@"peer_id"]) create:NO];
        if (c) {
            ACMessage *nm = [self messageFrom:m chat:c];
            for (NSUInteger i = 0; i < [c.messages count]; i++) {
                ACMessage *old = [c.messages objectAtIndex:i];
                if (old.msgId == nm.msgId) {
                    if (old.media && nm.media && old.media.mediaId == nm.media.mediaId) nm.media = old.media;
                    [c.messages replaceObjectAtIndex:i withObject:nm]; [self notifyChats:c]; break; }
            }
        }
    } else if ([t isEqualToString:@"updatePhoneCall"]) {
        NSDictionary *pc = DictOf([u objectForKey:@"phone_call"]);
        if (pc) [[ACCall shared] handlePhoneCall:pc];
    } else if ([t isEqualToString:@"updateDeleteMessages"]) {
        NSArray *ids = ArrOf([u objectForKey:@"messages"]);
        BOOL changed = NO;
        for (ACChat *c in _chats) {
            for (NSInteger i = (NSInteger)[c.messages count] - 1; i >= 0; i--) {
                ACMessage *m = [c.messages objectAtIndex:(NSUInteger)i];
                if (m.msgId != 0 && [ids containsObject:[NSNumber numberWithInt:m.msgId]]) { [c.messages removeObjectAtIndex:(NSUInteger)i]; changed = YES; }
            }
        }
        if (changed) [self notifyChats:nil];
    }
}

@end
