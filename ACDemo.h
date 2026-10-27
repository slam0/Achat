#import <Foundation/Foundation.h>

/* Dane demonstracyjne (etap 1: sam wygląd, bez połączenia z Telegramem). */

@interface ACMessage : NSObject
@property (nonatomic, copy) NSString *text, *time;
@property (nonatomic) BOOL outgoing;
@end

@interface ACChat : NSObject
@property (nonatomic, copy) NSString *name, *status;
@property (nonatomic) NSInteger unread;
@property (nonatomic, strong) NSMutableArray *messages;       /* ACMessage */
@property (nonatomic, readonly) NSString *preview;
@property (nonatomic, readonly) NSString *lastTime;
- (void)addMessage:(NSString *)text outgoing:(BOOL)outgoing;
@end

@interface ACDemo : NSObject
+ (NSMutableArray *)chats;                                    /* ACChat */
+ (NSString *)nowString;                                      /* "21:07" */
+ (NSString *)autoReplyFor:(ACChat *)chat;
@end
