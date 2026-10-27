#import "ACStore.h"

@implementation ACStore {
    NSMutableDictionary *_d;
}

static NSString *PlistPath(void)
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[dirs objectAtIndex:0] stringByAppendingPathComponent:@"aerochat.plist"];
}

+ (ACStore *)shared
{
    static ACStore *s;
    if (!s) s = [[ACStore alloc] init];
    return s;
}

- (id)init
{
    if ((self = [super init])) {
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:PlistPath()];
        _d = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSInteger)themeIndex { return [[_d objectForKey:@"theme"] integerValue]; }

- (void)setThemeIndex:(NSInteger)i
{
    [_d setObject:[NSNumber numberWithInteger:i] forKey:@"theme"];
    [self save];
}

- (void)save { [_d writeToFile:PlistPath() atomically:YES]; }

@end
