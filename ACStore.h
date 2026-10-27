#import <Foundation/Foundation.h>

/* Ustawienia aplikacji (na razie tylko motyw), zapisywane w Documents/aerochat.plist. */
@interface ACStore : NSObject
+ (ACStore *)shared;
@property (nonatomic) NSInteger themeIndex;
- (void)save;
@end
