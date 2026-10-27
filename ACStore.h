#import <Foundation/Foundation.h>

/* Ustawienia aplikacji (na razie tylko motyw), zapisywane w Documents/aerochat.plist. */
@interface ACStore : NSObject
+ (ACStore *)shared;
@property (nonatomic) NSInteger themeIndex;
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)obj forKey:(NSString *)key;      /* nil usuwa; zapis od razu */
- (void)save;
@end
