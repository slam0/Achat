#import <UIKit/UIKit.h>

/* Konfiguracja w stylu asystenta iOS 5/6: ekran powitalny z przyciskiem, potem numer telefonu -> kod -> (hasło 2FA) -> gotowe. */
@interface ACSetupController : NSObject
+ (void)presentFrom:(UIViewController *)host;
@end
