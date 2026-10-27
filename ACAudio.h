#import <Foundation/Foundation.h>
#include <stdint.h>

/* Dźwięk rozmowy: mikrofon i głośnik przez AudioUnit (z usuwaniem echa, jeśli telefon pozwala), 16 kHz mono. */
typedef void (*ACAudioPushFn)(void *engine, const int16_t *pcm, int n);     /* mikrofon -> silnik */
typedef void (*ACAudioPullFn)(void *engine, int16_t *pcm, int n);           /* silnik -> głośnik */

@interface ACAudio : NSObject
- (BOOL)startWithEngine:(void *)engine push:(ACAudioPushFn)push pull:(ACAudioPullFn)pull error:(NSString **)err;
- (void)stop;
- (void)setSpeaker:(BOOL)on;
@property (nonatomic, readonly) BOOL running;
@end
