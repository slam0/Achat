#import "ACCall.h"
#import "ACTelegram.h"
#import "ACTelegramPrivate.h"
#import "ACAudio.h"
#import "ACCallController.h"
#import "ACStore.h"
#import "ACCrash.h"
#include "ac_voip.h"
#include "ac_dh.h"
#include "tg_crypto.h"
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

NSString *const ACCallDidChangeNotification = @"ACCallDidChangeNotification";

#define PROTO_MIN_LAYER 65
#define PROTO_MAX_LAYER 92
#define PROTO_LIB @"2.4.4"

static NSString *Hex(NSData *d)
{
    const uint8_t *b = (const uint8_t *)[d bytes];
    NSMutableString *s = [NSMutableString stringWithCapacity:[d length] * 2];
    for (NSUInteger i = 0; i < [d length]; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}
static NSData *UnHex(NSString *s)
{
    NSUInteger n = [s length] / 2;
    NSMutableData *d = [NSMutableData dataWithLength:n];
    uint8_t *p = (uint8_t *)[d mutableBytes];
    for (NSUInteger i = 0; i < n; i++) {
        unsigned v = 0;
        NSString *two = [s substringWithRange:NSMakeRange(i * 2, 2)];
        sscanf([two UTF8String], "%2x", &v);
        p[i] = (uint8_t)v;
    }
    return d;
}
static NSString *LS(long long v) { return [NSString stringWithFormat:@"%lld", v]; }
static int IntOf(id o) { return [o respondsToSelector:@selector(intValue)] ? [o intValue] : 0; }
static long long LongOf(id o) { return [o respondsToSelector:@selector(longLongValue)] ? [o longLongValue] : 0; }
static BOOL BoolOf(id o) { return [o respondsToSelector:@selector(boolValue)] ? [o boolValue] : NO; }
static NSString *StrOf(id o) { return [o isKindOfClass:[NSString class]] ? o : @""; }
static NSDictionary *DictOf(id o) { return [o isKindOfClass:[NSDictionary class]] ? o : nil; }
static NSArray *ArrOf(id o) { return [o isKindOfClass:[NSArray class]] ? o : [NSArray array]; }

/* "klucz" rozmowy: ostatnie 8 bajtów skrótu SHA-1 (jak auth_key_id w MTProto) */
static long long KeyFingerprint(const uint8_t key[256])
{
    uint8_t h[20];
    unsigned long long v = 0;
    int i;
    tg_sha1(key, 256, h);
    for (i = 7; i >= 0; i--) v = (v << 8) | h[12 + i];
    return (long long)v;
}

/* skrót SHA-256 liczby p jako tekst (do zapamiętania, że ta liczba już przeszła test pierwszości) */
static NSString *PrimeKey(const uint8_t *p)
{
    uint8_t hash[32];
    int i;
    NSMutableString *s = [NSMutableString string];
    tg_sha256(p, 256, hash);
    for (i = 0; i < 32; i++) [s appendFormat:@"%02x", hash[i]];
    return s;
}

/* a = losowe 256 B xor losowość z serwera; ga = g^a mod p. 0 = ok. Działa w tle, nie dotyka ACStore. */
static int DHPrepare(const uint8_t *p, size_t plen, int g, const uint8_t *rnd, size_t rlen, BOOL primeKnown, uint8_t a[256], uint8_t ga[256])
{
    uint8_t gb;
    size_t i;
    if (plen != 256 || g < 2 || g > 7) return -1;
    if (!primeKnown && acdh_check_prime(p) != 0) return -2;
    tg_random(a, 256);
    for (i = 0; i < 256 && i < rlen; i++) a[i] ^= rnd[i];
    gb = (uint8_t)g;
    if (acdh_pow(p, &gb, 1, a, ga) != 0) return -3;
    if (acdh_check_public(p, ga) != 0) return -4;
    return 0;
}

static void EngineState(void *ud, int st, int err);
static void EngineLog(const char *line);

/* Dziennik rozmów: Documents/aerochat-call.log (widoczny przez udostępnianie plików w iTunes albo Filzę) */
static void CallLog(NSString *line)
{
    static NSDateFormatter *f;
    if (!f) { f = [[NSDateFormatter alloc] init]; [f setDateFormat:@"HH:mm:ss"]; }
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = [[dirs objectAtIndex:0] stringByAppendingPathComponent:@"aerochat-call.log"];
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    if ([old length] > 60000) old = [old substringFromIndex:[old length] - 30000];
    NSString *out = [old stringByAppendingFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], line];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *JSONText(id o)
{
    if (!o || ![NSJSONSerialization isValidJSONObject:o]) return @"?";
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"?";
}

@implementation ACCall {
    ACCallState _state;
    BOOL _outgoing, _muted, _speaker, _peerMuted, _reconnecting, _mediaStarted;
    NSString *_peerName, *_status;
    long long _callId, _accessHash, _peerId, _peerAccess;
    NSData *_p;
    int _g;
    NSData *_priv, *_pub;           /* nasza liczba tajna i publiczna */
    NSData *_gAHash;                /* przychodząca: skrót g_a od dzwoniącego */
    NSData *_key;                   /* wspólny klucz 256 B */
    int _gen;                       /* zmienia się z każdą nową rozmową; odrzuca spóźnione odpowiedzi */
    acv *_engine;
    ACAudio *_audio;
    NSDate *_activeSince;
    NSTimer *_tick, *_ring;
    ACCallController *_ui;
}

@synthesize state = _state, peerName = _peerName, outgoing = _outgoing, peerMuted = _peerMuted, muted = _muted, speaker = _speaker;

+ (ACCall *)shared
{
    static ACCall *s;
    if (!s) s = [[ACCall alloc] init];
    return s;
}

- (BOOL)inProgress { return _state != ACCallIdle && _state != ACCallEnded; }

- (NSString *)statusText
{
    if (_state == ACCallActive && !_reconnecting) {
        int sec = _activeSince ? (int)(-[_activeSince timeIntervalSinceNow]) : 0;
        NSString *t = [NSString stringWithFormat:@"%d:%02d", sec / 60, sec % 60];
        return _peerMuted ? [t stringByAppendingString:@" · rozmówca wyciszony"] : t;
    }
    return _status ?: @"";
}

- (void)changed { [[NSNotificationCenter defaultCenter] postNotificationName:ACCallDidChangeNotification object:self]; }

- (void)setState:(ACCallState)s status:(NSString *)status
{
    _state = s;
    _status = status;
    if (s == ACCallIdle) [self dismissUI]; else [self presentUI];
    [self changed];
}

/* ---------- interfejs ---------- */

- (void)presentUI
{
    if (_ui) return;
    UIViewController *vc = [[[UIApplication sharedApplication] keyWindow] rootViewController];
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    _ui = [[ACCallController alloc] init];
    _ui.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [vc presentViewController:_ui animated:YES completion:nil];
}

- (void)dismissUI
{
    ACCallController *u = _ui;
    _ui = nil;
    if (u) [u dismissViewControllerAnimated:YES completion:nil];
}

- (void)startRing
{
    [self stopRing];
    [self ringOnce];
    _ring = [NSTimer scheduledTimerWithTimeInterval:2.5 target:self selector:@selector(ringOnce) userInfo:nil repeats:YES];
}

- (void)ringOnce
{
    AudioServicesPlaySystemSound(1005);
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

- (void)stopRing { [_ring invalidate]; _ring = nil; }

/* ---------- pomocnicze ---------- */

- (NSDictionary *)protocolInfo
{
    return [NSDictionary dictionaryWithObjectsAndKeys:@"phoneCallProtocol", @"_", [NSNumber numberWithBool:YES], @"udp_reflector",
            [NSNumber numberWithInt:PROTO_MIN_LAYER], @"min_layer", [NSNumber numberWithInt:PROTO_MAX_LAYER], @"max_layer",
            [NSArray arrayWithObject:PROTO_LIB], @"library_versions", nil];
}

- (NSDictionary *)inputCall
{
    return [NSDictionary dictionaryWithObjectsAndKeys:@"inputPhoneCall", @"_", LS(_callId), @"id", LS(_accessHash), @"access_hash", nil];
}

static NSString *ReasonError(NSString *e)
{
    if ([e hasPrefix:@"USER_PRIVACY_RESTRICTED"]) return @"Ten użytkownik nie przyjmuje od Ciebie połączeń.";
    if ([e hasPrefix:@"USER_IS_BLOCKED"]) return @"Ten użytkownik Cię zablokował.";
    if ([e hasPrefix:@"PARTICIPANT_VERSION_OUTDATED"]) return @"Rozmówca ma zbyt starą wersję Telegrama.";
    if ([e hasPrefix:@"CALL_PROTOCOL_LAYER_INVALID"] || [e hasPrefix:@"CALL_PROTOCOL_FLAGS_INVALID"]) return @"Rozmówca używa niezgodnej wersji rozmów.";
    if ([e hasPrefix:@"USER_DEACTIVATED"]) return @"To konto jest nieaktywne.";
    if ([e hasPrefix:@"FLOOD_WAIT"]) return @"Za dużo prób. Spróbuj za chwilę.";
    if ([e hasPrefix:@"CALL_ALREADY_DECLINED"] || [e hasPrefix:@"CALL_ALREADY_ACCEPTED"]) return @"Rozmowa została już zakończona.";
    return [NSString stringWithFormat:@"Nie udało się nawiązać rozmowy (%@).", e];
}

- (void)resetCall
{
    _gen++;
    [self stopRing];
    [_tick invalidate]; _tick = nil;
    [self stopMedia];
    _callId = _accessHash = _peerId = _peerAccess = 0;
    _p = nil; _g = 0; _priv = nil; _pub = nil; _gAHash = nil; _key = nil;
    _mediaStarted = NO; _reconnecting = NO; _peerMuted = NO;
    _muted = NO; _speaker = NO;
    _activeSince = nil;
    _peerName = nil;
}

/* ---------- wychodząca ---------- */

- (NSString *)startCallWithChat:(ACChat *)chat
{
    ACTelegram *tg = [ACTelegram shared];
    if (self.inProgress) return @"Trwa już inna rozmowa.";
    if (!tg.live || !tg.online) return @"Brak połączenia z Telegramem.";
    if (chat.peerKind != 1 || chat.peerId == 0) return @"Dzwonić można tylko do pojedynczych użytkowników.";
    if (chat.peerId == [tg myUserId]) return @"Nie można zadzwonić do siebie.";
    [self resetCall];
    _outgoing = YES;
    _peerId = chat.peerId;
    _peerAccess = chat.accessHash;
    _peerName = chat.name;
    [self setState:ACCallPreparing status:@"Przygotowanie…"];
    int gen = _gen;
    [self prepareKeyThen:^(NSString *err) {
        if (gen != _gen) return;
        if (err) { [self endLocally:err]; return; }
        [self sendRequestCall];
    }];
    return nil;
}

/* getDhConfig + liczba tajna i publiczna */
- (void)prepareKeyThen:(void (^)(NSString *err))done
{
    int gen = _gen;
    ACTelegram *tg = [ACTelegram shared];
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"messages.getDhConfig", @"_", [NSNumber numberWithInt:0], @"version",
                         [NSNumber numberWithInt:256], @"random_length", nil];
    [tg call:req done:^(id res, NSString *err, int code) {
        if (gen != _gen) return;
        NSDictionary *d = DictOf(res);
        if (err || ![StrOf([d objectForKey:@"_"]) isEqualToString:@"messages.dhConfig"]) {
            done(err ? ReasonError(err) : @"Serwer przysłał niepoprawne parametry szyfrowania.");
            return;
        }
        NSData *p = UnHex(StrOf([d objectForKey:@"p"])), *rnd = UnHex(StrOf([d objectForKey:@"random"]));
        int g = IntOf([d objectForKey:@"g"]);
        NSString *pk = [p length] == 256 ? PrimeKey((const uint8_t *)[p bytes]) : @"";
        BOOL known = [[[ACStore shared] objectForKey:@"tg.dhok"] isEqual:pk];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            uint8_t a[256], ga[256];
            int r = DHPrepare((const uint8_t *)[p bytes], [p length], g, (const uint8_t *)[rnd bytes], [rnd length], known, a, ga);
            NSData *ad = [NSData dataWithBytes:a length:256], *gd = [NSData dataWithBytes:ga length:256];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != _gen) return;
                if (r != 0) { done(@"Serwer przysłał niepoprawne parametry szyfrowania."); return; }
                if (!known) [[ACStore shared] setObject:pk forKey:@"tg.dhok"];
                _p = p; _g = g; _priv = ad; _pub = gd;
                done(nil);
            });
        });
    }];
}

- (void)sendRequestCall
{
    int gen = _gen;
    uint8_t h[32];
    tg_sha256((const uint8_t *)[_pub bytes], 256, h);
    NSDictionary *user = [NSDictionary dictionaryWithObjectsAndKeys:@"inputUser", @"_", LS(_peerId), @"user_id", LS(_peerAccess), @"access_hash", nil];
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"phone.requestCall", @"_", user, @"user_id",
                         [NSNumber numberWithInt:(int)arc4random()], @"random_id", Hex([NSData dataWithBytes:h length:32]), @"g_a_hash",
                         [self protocolInfo], @"protocol", nil];
    [[ACTelegram shared] call:req done:^(id res, NSString *err, int code) {
        NSDictionary *pc = DictOf([DictOf(res) objectForKey:@"phone_call"]);
        if (gen != _gen) {
            /* anulowaliśmy zanim serwer odpowiedział: zamknij rozmowę po stronie serwera */
            if (pc && LongOf([pc objectForKey:@"id"]) != 0) [self discardId:LongOf([pc objectForKey:@"id"]) access:LongOf([pc objectForKey:@"access_hash"]) reason:@"phoneCallDiscardReasonHangup" duration:0];
            return;
        }
        if (err || !pc) { CallLog([NSString stringWithFormat:@"requestCall błąd: %@ (%d)", err, code]); [self endLocally:err ? ReasonError(err) : @"Serwer nie odpowiedział."]; return; }
        [[ACTelegram shared] cacheEntities:DictOf(res)];
        [self handlePhoneCall:pc];
    }];
}

/* serwer: rozmówca odebrał (g_b) */
- (void)outgoingAccepted:(NSDictionary *)pc
{
    int gen = _gen;
    NSData *gb = UnHex(StrOf([pc objectForKey:@"g_b"]));
    if ([gb length] != 256 || !_p || !_priv) { [self failCall:@"Niepoprawna odpowiedź rozmówcy."]; return; }
    [self setState:ACCallConnecting status:@"Łączenie…"];
    NSData *p = _p, *a = _priv;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint8_t key[256];
        int r = -1;
        if (acdh_check_public((const uint8_t *)[p bytes], (const uint8_t *)[gb bytes]) == 0)
            r = acdh_pow((const uint8_t *)[p bytes], (const uint8_t *)[gb bytes], 256, (const uint8_t *)[a bytes], key);
        NSData *kd = r == 0 ? [NSData dataWithBytes:key length:256] : nil;
        memset(key, 0, sizeof(key));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != _gen) return;
            if (!kd) { [self failCall:@"Błąd wymiany kluczy."]; return; }
            _key = kd;
            NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"phone.confirmCall", @"_", [self inputCall], @"peer",
                                 Hex(_pub), @"g_a", LS(KeyFingerprint((const uint8_t *)[_key bytes])), @"key_fingerprint",
                                 [self protocolInfo], @"protocol", nil];
            [[ACTelegram shared] call:req done:^(id res, NSString *err, int code) {
                if (gen != _gen) return;
                NSDictionary *c = DictOf([DictOf(res) objectForKey:@"phone_call"]);
                if (err || !c) { CallLog([NSString stringWithFormat:@"confirmCall błąd: %@ (%d)", err, code]); [self failCall:err ? ReasonError(err) : @"Serwer nie odpowiedział."]; return; }
                [self handlePhoneCall:c];
            }];
        });
    });
}

/* ---------- przychodząca ---------- */

- (void)incomingRequested:(NSDictionary *)pc
{
    ACTelegram *tg = [ACTelegram shared];
    long long cid = LongOf([pc objectForKey:@"id"]), acc = LongOf([pc objectForKey:@"access_hash"]);
    if (LongOf([pc objectForKey:@"participant_id"]) != [tg myUserId]) return;
    if (self.inProgress) {
        if (cid != _callId) [self discardId:cid access:acc reason:@"phoneCallDiscardReasonBusy" duration:0];
        return;
    }
    NSDictionary *proto = DictOf([pc objectForKey:@"protocol"]);
    NSArray *libs = ArrOf([proto objectForKey:@"library_versions"]);
    BOOL okLayer = IntOf([proto objectForKey:@"min_layer"]) <= PROTO_MAX_LAYER && IntOf([proto objectForKey:@"max_layer"]) >= PROTO_MAX_LAYER;
    BOOL okLib = [libs count] == 0 || [libs containsObject:PROTO_LIB];
    BOOL video = BoolOf([pc objectForKey:@"video"]);
    long long from = LongOf([pc objectForKey:@"admin_id"]);
    NSDictionary *u = [tg cachedUser:from];
    NSString *name = u ? [tg displayNameOfUser:u] : [NSString stringWithFormat:@"Użytkownik %lld", from];
    CallLog([NSString stringWithFormat:@"połączenie przychodzące od %lld, protokół: %@, wideo=%d", from, JSONText(proto), (int)video]);
    if (!okLayer || !okLib || video) {
        NSMutableArray *why = [NSMutableArray array];
        if (video) [why addObject:@"wideo"];
        if (!okLayer) [why addObject:[NSString stringWithFormat:@"warstwy %d–%d", IntOf([proto objectForKey:@"min_layer"]), IntOf([proto objectForKey:@"max_layer"])]];
        if (!okLib) [why addObject:[NSString stringWithFormat:@"biblioteki: %@", [libs count] ? [libs componentsJoinedByString:@", "] : @"brak"]];
        NSString *detail = [why componentsJoinedByString:@"; "];
        CallLog([@"odrzucono: " stringByAppendingString:detail]);
        [self discardId:cid access:acc reason:@"phoneCallDiscardReasonHangup" duration:0];
        [self resetCall];
        _outgoing = NO;
        _peerName = name;
        [self setState:ACCallEnded status:[NSString stringWithFormat:@"Odrzucono połączenie — niezgodność: %@. Aplikacja obsługuje tylko bibliotekę 2.4.4, warstwy 65–92, bez wideo.", detail]];
        [self scheduleIdleAfter:15000];
        return;
    }
    [self resetCall];
    _outgoing = NO;
    _callId = cid;
    _accessHash = acc;
    _peerId = from;
    _peerName = name;
    _gAHash = UnHex(StrOf([pc objectForKey:@"g_a_hash"]));
    [tg call:[NSDictionary dictionaryWithObjectsAndKeys:@"phone.receivedCall", @"_", [self inputCall], @"peer", nil] done:^(id r, NSString *e, int c) {}];
    [self setState:ACCallIncoming status:@"Połączenie przychodzące…"];
    [self startRing];
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        UILocalNotification *n = [[UILocalNotification alloc] init];
        n.alertBody = [NSString stringWithFormat:@"Dzwoni %@", name];
        n.soundName = UILocalNotificationDefaultSoundName;
        [[UIApplication sharedApplication] presentLocalNotificationNow:n];
    }
    int gen = _gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == _gen && _state == ACCallIncoming) {
            [self discardId:_callId access:_accessHash reason:@"phoneCallDiscardReasonMissed" duration:0];
            [self endLocally:@"Nieodebrane połączenie."];
        }
    });
}

- (void)accept
{
    if (_state != ACCallIncoming) return;
    int gen = _gen;
    [self stopRing];
    [self setState:ACCallConnecting status:@"Łączenie…"];
    [self prepareKeyThen:^(NSString *err) {
        if (gen != _gen) return;
        if (err) { [self failCall:err]; return; }
        NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"phone.acceptCall", @"_", [self inputCall], @"peer",
                             Hex(_pub), @"g_b", [self protocolInfo], @"protocol", nil];
        [[ACTelegram shared] call:req done:^(id res, NSString *e, int code) {
            if (gen != _gen) return;
            NSDictionary *c = DictOf([DictOf(res) objectForKey:@"phone_call"]);
            if (e || !c) { CallLog([NSString stringWithFormat:@"acceptCall błąd: %@ (%d)", e, code]); [self failCall:e ? ReasonError(e) : @"Serwer nie odpowiedział."]; return; }
            [self handlePhoneCall:c];
        }];
    }];
}

/* ---------- aktualizacje z serwera ---------- */

- (void)handlePhoneCall:(NSDictionary *)pc
{
    NSString *t = StrOf([pc objectForKey:@"_"]);
    long long cid = LongOf([pc objectForKey:@"id"]);
    CallLog([NSString stringWithFormat:@"serwer: %@ id=%lld stan=%d%@", t, cid, (int)_state,
             [pc objectForKey:@"reason"] ? [@" powód=" stringByAppendingString:JSONText([pc objectForKey:@"reason"])] : @""]);
    if ([t isEqualToString:@"phoneCallRequested"]) { [self incomingRequested:pc]; return; }
    if (_state == ACCallIdle || _state == ACCallEnded) return;
    if (_callId == 0 && _outgoing && [t isEqualToString:@"phoneCallWaiting"]) {
        _callId = cid;
        _accessHash = LongOf([pc objectForKey:@"access_hash"]);
    }
    if (cid == 0 || cid != _callId) return;
    if ([t isEqualToString:@"phoneCallWaiting"]) {
        if (_outgoing && _state == ACCallPreparing) {
            [self setState:ACCallRinging status:[pc objectForKey:@"receive_date"] ? @"Dzwoni…" : @"Łączenie…"];
        } else if (_outgoing && _state == ACCallRinging && [pc objectForKey:@"receive_date"]) {
            [self setState:ACCallRinging status:@"Dzwoni…"];
        }
    } else if ([t isEqualToString:@"phoneCallAccepted"]) {
        if (_outgoing && !_key) [self outgoingAccepted:pc];
    } else if ([t isEqualToString:@"phoneCall"]) {
        [self callReady:pc];
    } else if ([t isEqualToString:@"phoneCallDiscarded"] || [t isEqualToString:@"phoneCallEmpty"]) {
        NSString *rs = StrOf([DictOf([pc objectForKey:@"reason"]) objectForKey:@"_"]);
        NSString *msg;
        if ([rs isEqualToString:@"phoneCallDiscardReasonBusy"]) msg = @"Rozmówca jest zajęty.";
        else if ([rs isEqualToString:@"phoneCallDiscardReasonMissed"]) msg = _outgoing ? @"Brak odpowiedzi." : @"Nieodebrane połączenie.";
        else if ([rs isEqualToString:@"phoneCallDiscardReasonDisconnect"]) msg = @"Połączenie przerwane.";
        else msg = _state == ACCallActive ? @"Rozmowa zakończona." : (_outgoing ? @"Rozmówca odrzucił połączenie." : @"Połączenie anulowane.");
        [self endLocally:msg];
    }
}

/* mamy komplet danych: liczymy klucz (przychodząca) albo sprawdzamy go (wychodząca) i startujemy dźwięk */
- (void)callReady:(NSDictionary *)pc
{
    if (_mediaStarted) return;
    int gen = _gen;
    long long fp = LongOf([pc objectForKey:@"key_fingerprint"]);
    NSArray *conns = ArrOf([pc objectForKey:@"connections"]);
    if (_outgoing) {
        if (!_key) return;
        if (KeyFingerprint((const uint8_t *)[_key bytes]) != fp) { [self failCall:@"Błąd klucza szyfrowania."]; return; }
        _mediaStarted = YES;
        [self startMediaWithConnections:conns];
        return;
    }
    NSData *ga = UnHex(StrOf([pc objectForKey:@"g_a_or_b"]));
    if ([ga length] != 256 || !_p || !_priv || !_gAHash) { [self failCall:@"Niepoprawna odpowiedź serwera."]; return; }
    uint8_t h[32];
    tg_sha256((const uint8_t *)[ga bytes], 256, h);
    if ([_gAHash length] != 32 || memcmp(h, [_gAHash bytes], 32) != 0) { [self failCall:@"Błąd klucza szyfrowania."]; return; }
    _mediaStarted = YES;
    NSData *p = _p, *b = _priv;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint8_t key[256];
        int r = -1;
        if (acdh_check_public((const uint8_t *)[p bytes], (const uint8_t *)[ga bytes]) == 0)
            r = acdh_pow((const uint8_t *)[p bytes], (const uint8_t *)[ga bytes], 256, (const uint8_t *)[b bytes], key);
        NSData *kd = r == 0 ? [NSData dataWithBytes:key length:256] : nil;
        BOOL match = kd && KeyFingerprint(key) == fp;
        memset(key, 0, sizeof(key));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != _gen) return;
            if (!match) { [self failCall:@"Błąd klucza szyfrowania."]; return; }
            _key = kd;
            [self startMediaWithConnections:conns];
        });
    });
}

/* ---------- dźwięk i silnik ---------- */

- (void)startMediaWithConnections:(NSArray *)conns
{
    if ([_key length] != 256) { [self failCall:@"Brak klucza."]; return; }
    CallLog([NSString stringWithFormat:@"start dźwięku, serwery: %@", JSONText(conns)]);
    acv_set_log(EngineLog);
    acv *v = acv_new((const uint8_t *)[_key bytes], _outgoing ? 1 : 0, EngineState, (void *)(intptr_t)_gen);
    if (!v) { [self failCall:@"Nie udało się uruchomić kodeka dźwięku."]; return; }
    int n = 0;
    for (id o in conns) {
        NSDictionary *c = DictOf(o);
        if (!c || ![StrOf([c objectForKey:@"_"]) isEqualToString:@"phoneConnection"] || BoolOf([c objectForKey:@"tcp"])) continue;
        NSString *ip = StrOf([c objectForKey:@"ip"]);
        NSData *tag = UnHex(StrOf([c objectForKey:@"peer_tag"]));
        if ([ip length] == 0 || [tag length] != 16) continue;
        if (acv_add_relay(v, [ip UTF8String], IntOf([c objectForKey:@"port"]), (const uint8_t *)[tag bytes]) == 0) n++;
    }
    if (n == 0) { acv_free(v); [self failCall:@"Telegram nie podał serwera rozmów."]; return; }
    ACAudio *audio = [[ACAudio alloc] init];
    NSString *aerr = nil;
    [audio setSpeaker:_speaker];
    if (![audio startWithEngine:v error:&aerr]) {
        acv_free(v);
        ACCrumb([@"audio start: " stringByAppendingString:aerr ?: @"?"]);
        [self failCall:[NSString stringWithFormat:@"Nie można uruchomić mikrofonu lub głośnika (%@).", aerr ?: @"?"]];
        return;
    }
    char err[120];
    if (acv_start(v, err, sizeof(err)) != 0) {
        [audio stop];
        acv_free(v);
        [self failCall:[NSString stringWithFormat:@"Nie można otworzyć połączenia (%s).", err]];
        return;
    }
    _engine = v;
    _audio = audio;
    if (_muted) acv_set_mute(_engine, 1);
    [self setState:ACCallConnecting status:@"Łączenie…"];
    _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tickOnce) userInfo:nil repeats:YES];
}

- (void)stopMedia
{
    if (_audio) { [_audio stop]; _audio = nil; }
    if (_engine) { acv_free(_engine); _engine = NULL; }
}

- (void)tickOnce
{
    if (_engine) {
        BOOL pm = acv_peer_muted(_engine) != 0;
        if (pm != _peerMuted) _peerMuted = pm;
    }
    [self changed];
}

- (void)engineState:(int)st error:(int)err gen:(int)gen
{
    CallLog([NSString stringWithFormat:@"silnik: stan=%d błąd=%d", st, err]);
    if (gen != _gen || !_engine) return;
    if (st == ACV_STATE_ESTABLISHED) {
        _reconnecting = NO;
        if (_state != ACCallActive) {
            _activeSince = [NSDate date];
            [self setState:ACCallActive status:@""];
        } else [self changed];
    } else if (st == ACV_STATE_RECONNECTING) {
        _reconnecting = YES;
        [self setState:_state status:@"Łączenie ponownie…"];
    } else if (st == ACV_STATE_FAILED) {
        NSString *m = err == ACV_ERR_TIMEOUT ? @"Nie udało się nawiązać połączenia z rozmówcą (brak odpowiedzi serwera rozmów)." :
                      err == ACV_ERR_INCOMPATIBLE ? @"Rozmówca używa niezgodnej wersji protokołu dźwięku (silnik)." : [NSString stringWithFormat:@"Błąd połączenia (kod %d).", err];
        [self discardId:_callId access:_accessHash reason:@"phoneCallDiscardReasonDisconnect" duration:_activeSince ? (int)(-[_activeSince timeIntervalSinceNow]) : 0];
        [self endLocally:m];
    } else if (_state == ACCallConnecting) {
        [self setState:ACCallConnecting status:@"Łączenie…"];
    }
}

- (void)setMuted:(BOOL)muted
{
    _muted = muted;
    if (_engine) acv_set_mute(_engine, muted ? 1 : 0);
    [self changed];
}

- (void)setSpeaker:(BOOL)speaker
{
    _speaker = speaker;
    [_audio setSpeaker:speaker];
    [self changed];
}

/* ---------- kończenie ---------- */

- (void)discardId:(long long)cid access:(long long)acc reason:(NSString *)reason duration:(int)dur
{
    if (cid == 0) return;
    NSDictionary *peer = [NSDictionary dictionaryWithObjectsAndKeys:@"inputPhoneCall", @"_", LS(cid), @"id", LS(acc), @"access_hash", nil];
    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:@"phone.discardCall", @"_", peer, @"peer", [NSNumber numberWithInt:dur], @"duration",
                         [NSDictionary dictionaryWithObject:reason forKey:@"_"], @"reason", @"0", @"connection_id", nil];
    [[ACTelegram shared] call:req done:^(id res, NSString *err, int code) {
        if (!err && res) [[ACTelegram shared] processUpdates:res];     /* wiadomość serwisowa o rozmowie trafia do czatu */
    }];
}

- (void)hangup
{
    if (_state == ACCallEnded) { _gen++; [self setState:ACCallIdle status:nil]; return; }      /* "Zamknij" na ekranie z błędem */
    if (_state == ACCallIdle) return;
    BOOL incoming = _state == ACCallIncoming;
    int dur = _activeSince ? (int)(-[_activeSince timeIntervalSinceNow]) : 0;
    [self discardId:_callId access:_accessHash reason:@"phoneCallDiscardReasonHangup" duration:dur];
    [self endLocally:incoming ? @"Odrzucono." : (_state == ACCallActive ? @"Rozmowa zakończona." : @"Anulowano.")];
}

- (void)failCall:(NSString *)text
{
    [self discardId:_callId access:_accessHash reason:@"phoneCallDiscardReasonDisconnect" duration:0];
    [self endLocally:text];
}

- (void)endLocally:(NSString *)text
{
    if (_state == ACCallIdle) return;
    CallLog([@"koniec: " stringByAppendingString:text ?: @""]);
    _gen++;                                    /* spóźnione odpowiedzi nie dotyczą już tej rozmowy */
    int gen = _gen;
    [self stopRing];
    [_tick invalidate]; _tick = nil;
    [self stopMedia];
    _callId = 0;
    _reconnecting = NO;
    [self setState:ACCallEnded status:text];
    BOOL plain = [text hasPrefix:@"Rozmowa zakończona"] || [text hasPrefix:@"Odrzucono."] || [text hasPrefix:@"Anulowano."] || [text hasPrefix:@"Połączenie anulowane"];
    [self scheduleIdleAfter:plain ? 1800 : 15000];
    (void)gen;
}

- (void)scheduleIdleAfter:(int)ms      /* milisekundy; liczby całkowite, bo konwersja double->int64 nie jest dostępna w iOS 6 */
{
    int gen = _gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * (int64_t)1000000), dispatch_get_main_queue(), ^{
        if (gen == _gen && _state == ACCallEnded) [self setState:ACCallIdle status:nil];
    });
}

- (void)sessionEnded
{
    if (_state == ACCallIdle) return;
    [self resetCall];
    [self setState:ACCallIdle status:nil];
}

@end

static void EngineState(void *ud, int st, int err)
{
    int gen = (int)(intptr_t)ud;
    dispatch_async(dispatch_get_main_queue(), ^{ [[ACCall shared] engineState:st error:err gen:gen]; });
}

static void EngineLog(const char *line)
{
    NSString *s = [NSString stringWithUTF8String:line ? line : ""];
    dispatch_async(dispatch_get_main_queue(), ^{ CallLog([@"silnik: " stringByAppendingString:s]); });
}
