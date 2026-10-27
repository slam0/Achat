#import "ACTelegram.h"

/* Wnętrzności ACTelegram współdzielone z obsługą załączników (ACTelegramMedia.m). */

typedef void (^ACTGDone)(id res, NSString *err, int code);

@interface ACTelegram (Private)
- (NSData *)encode:(NSDictionary *)obj error:(NSString **)err;
- (id)decode:(NSData *)d function:(NSString *)fn;
- (void)call:(NSDictionary *)obj done:(ACTGDone)done;                 /* wynik jako obiekt JSON */
- (void)callRaw:(NSDictionary *)obj done:(ACTGDone)done;              /* wynik jako surowy NSData (TL) */
- (NSDictionary *)wrapInit:(NSDictionary *)obj;                       /* invokeWithLayer + initConnection */
- (NSString *)ipForDC:(int)dc;
- (int)homeDC;
- (BOOL)connectedHome;
- (void)notifyChats:(ACChat *)chat;
- (void)mediaWipe;                                                     /* po wylogowaniu: kasuje pobrane pliki */
- (void)mediaSessionEnded;
- (void)processUpdates:(id)json;                                      /* aktualizacje (też z wyniku zapytania typu Updates) */
- (void)cacheEntities:(NSDictionary *)r;                              /* users / chats z odpowiedzi */
- (NSDictionary *)cachedUser:(long long)uid;
- (NSString *)displayNameOfUser:(NSDictionary *)u;
- (long long)myUserId;                                            /* zamyka dodatkowe połączenia do załączników */
@end
