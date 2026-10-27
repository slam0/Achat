#import <Foundation/Foundation.h>
#import "ACDemo.h"

/* Rozmowa głosowa 1:1 przez Telegram: sygnalizacja (phone.*), wymiana kluczy DH, silnik dźwięku zgodny z tgcalls 2.7.7 (ac_tgc). */

extern NSString *const ACCallDidChangeNotification;

typedef enum {
    ACCallIdle = 0,
    ACCallPreparing,     /* wychodząca: liczymy klucz i prosimy serwer o połączenie */
    ACCallRinging,       /* wychodząca: u rozmówcy dzwoni */
    ACCallIncoming,      /* przychodząca: czekamy na decyzję */
    ACCallConnecting,    /* klucz wymieniony, łączymy się z serwerem rozmów */
    ACCallActive,        /* rozmowa trwa */
    ACCallEnded          /* chwilowo pokazujemy, jak się skończyło */
} ACCallState;

@interface ACCall : NSObject
+ (ACCall *)shared;
@property (nonatomic, readonly) ACCallState state;
@property (nonatomic, readonly, copy) NSString *peerName;
@property (nonatomic, readonly) BOOL outgoing;
@property (nonatomic, readonly, copy) NSString *statusText;     /* druga linia na ekranie rozmowy (czas albo stan) */
@property (nonatomic, readonly) BOOL peerMuted;
@property (nonatomic, readonly) BOOL muted, speaker;
@property (nonatomic, readonly) BOOL inProgress;                /* każdy stan poza Idle i Ended */

- (NSString *)startCallWithChat:(ACChat *)chat;                  /* zwraca komunikat błędu albo nil */
- (void)accept;
- (void)hangup;                                                  /* rozłącz / odrzuć / anuluj */
- (void)setMuted:(BOOL)muted;
- (void)setSpeaker:(BOOL)speaker;

/* z ACTelegram */
- (void)handlePhoneCall:(NSDictionary *)phoneCall;
- (void)signalingData:(NSData *)data callId:(long long)callId;     /* updatePhoneCallSignalingData */
- (void)sessionEnded;                                            /* wylogowanie: natychmiast przerwij */
@end
