#import <Foundation/Foundation.h>
#import "ACDemo.h"

/* Połączenie z Telegramem (własny klient MTProto 2.0 w C, schemat TL ładowany z api.tl). */

extern NSString *const ACTGStateDidChangeNotification;     /* zmiana stanu logowania / połączenia */
extern NSString *const ACTGChatsDidChangeNotification;     /* zmiana listy czatów lub wiadomości; userInfo[@"chat"] = ACChat albo brak */

extern NSString *const ACTGMediaDidChangeNotification;      /* postęp / koniec pobierania załącznika; userInfo[@"media"] = ACMedia, @"relayout" = NSNumber BOOL */

typedef enum {
    ACTGStateOffline = 0,      /* niezalogowany */
    ACTGStateConnecting,       /* łączenie / logowanie w toku */
    ACTGStateNeedCode,         /* czekamy na kod z SMS-a lub aplikacji */
    ACTGStateNeedPassword,     /* konto ma hasło dwuskładnikowe */
    ACTGStateReady             /* zalogowany (połączony albo próbuje się połączyć ponownie) */
} ACTGState;

@interface ACTelegram : NSObject

+ (ACTelegram *)shared;

@property (nonatomic, readonly) ACTGState state;
@property (nonatomic, readonly) BOOL busy;                         /* trwa zapytanie logowania */
@property (nonatomic, readonly) BOOL authorized;                   /* mamy zapisaną, ważną sesję */
@property (nonatomic, readonly) BOOL live;                         /* pokazujemy prawdziwe czaty zamiast demo */
@property (nonatomic, readonly) BOOL online;                       /* gniazdo połączone */
@property (nonatomic, readonly, copy) NSString *statusText;        /* krótki opis stanu do paska tytułu */
@property (nonatomic, readonly, copy) NSString *lastError;         /* ostatni błąd po polsku (albo nil) */
@property (nonatomic, readonly, copy) NSString *codeInfo;          /* gdzie wysłano kod */
@property (nonatomic, readonly, copy) NSString *passwordHint;
@property (nonatomic, readonly, copy) NSString *userName;
@property (nonatomic, readonly, copy) NSString *phone;
@property (nonatomic, readonly, strong) NSMutableArray *chats;     /* ACChat */

/* dane aplikacji z my.telegram.org */
@property (nonatomic, readonly) int apiId;
@property (nonatomic, readonly, copy) NSString *apiHash;
@property (nonatomic, readonly) BOOL hasCredentials;
@property (nonatomic, readonly) BOOL builtInKeys;                  /* klucze wbudowane w aplikację przy budowaniu */
- (void)saveApiId:(int)apiId apiHash:(NSString *)apiHash;

/* logowanie */
- (void)startLoginWithPhone:(NSString *)phone;
- (void)submitCode:(NSString *)code;
- (void)submitPassword:(NSString *)password;
- (void)resendCode;
- (void)cancelLogin;                       /* wraca do kroku z numerem */
- (void)logOut;

/* cykl życia */
- (void)resume;                            /* przy starcie: połącz się, jeśli jest zapisana sesja */
- (void)appBecameActive;
- (void)enteredBackground;

/* dane */
- (void)reloadDialogs;
- (void)loadHistoryForChat:(ACChat *)chat;
- (void)sendText:(NSString *)text toChat:(ACChat *)chat;
- (void)markReadChat:(ACChat *)chat;

@end

/* załączniki (ACTelegramMedia.m) */
@interface ACTelegram (Media)
- (void)loadThumb:(ACMedia *)media;                          /* miniatura: z dysku od razu, inaczej w tle (powiadomienie ACTGMediaDidChange) */
- (void)downloadMedia:(ACMedia *)media openMode:(int)mode;   /* pełny plik; mode: 1 podgląd po pobraniu, 2 "otwórz w…" */
@end
