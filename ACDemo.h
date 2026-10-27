#import <Foundation/Foundation.h>

/* Dane demonstracyjne (etap 1: sam wygląd, bez połączenia z Telegramem). */

@interface ACMessage : NSObject
@property (nonatomic, copy) NSString *text, *time;
@property (nonatomic) BOOL outgoing;
/* tylko wiadomości z Telegrama */
@property (nonatomic) int msgId, date;
@property (nonatomic) long long randomId;
@property (nonatomic) BOOL pending, failed;
@end

@interface ACChat : NSObject
@property (nonatomic, copy) NSString *name, *status;
@property (nonatomic) NSInteger unread;
/* tylko czaty z Telegrama: 0 = demo, 1 = użytkownik, 2 = zwykła grupa, 3 = kanał / supergrupa */
@property (nonatomic) int peerKind;
@property (nonatomic) long long peerId, accessHash;
@property (nonatomic) int lastDate;
@property (nonatomic) BOOL historyLoaded, loadingHistory, isGroup, canWrite;
@property (nonatomic, strong) NSMutableArray *messages;       /* ACMessage */
@property (nonatomic, readonly) NSString *preview;
@property (nonatomic, readonly) NSString *lastTime;
- (void)addMessage:(NSString *)text outgoing:(BOOL)outgoing;
/* wyszukiwanie bez rozróżniania wielkości liter i polskich znaków: nazwa, status i treść wiadomości;
   snippet = fragment do pokazania na liście (ostatnia pasująca wiadomość albo zwykły podgląd) */
- (BOOL)matchesQuery:(NSString *)query snippet:(NSString **)snippet;
@end

@interface ACDemo : NSObject
+ (NSMutableArray *)chats;                                    /* ACChat: prawdziwe po zalogowaniu, inaczej demo */
+ (NSMutableArray *)demoChats;
+ (NSString *)nowString;
BOOL ACTextMatches(NSString *text, NSString *query);          /* bez wielkości liter i diakrytyków */                                      /* "21:07" */
+ (NSString *)autoReplyFor:(ACChat *)chat;
@end
