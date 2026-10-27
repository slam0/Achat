#import <Foundation/Foundation.h>
#include "ac_voip.h"

/* Dźwięk rozmowy: mikrofon i głośnik przez AudioUnit (z usuwaniem echa, jeśli telefon pozwala), 16 kHz mono. */
@interface ACAudio : NSObject
- (BOOL)startWithEngine:(acv *)engine error:(NSString **)err;
- (void)stop;
- (void)setSpeaker:(BOOL)on;
@property (nonatomic, readonly) BOOL running;
@end
