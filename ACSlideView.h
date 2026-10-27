#import <UIKit/UIKit.h>

/* Suwak "przesuń, aby skonfigurować" z ekranu aktywacji iOS 5/6: grafitowy pas, czarny tor, srebrny uchwyt ze strzałką
   i przebiegający połysk napisu. Po przesunięciu do końca wysyła UIControlEventValueChanged. */
@interface ACSlideView : UIControl
@property (nonatomic, copy) NSString *title;
- (void)reset;
@end
