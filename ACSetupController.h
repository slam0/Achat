#import <UIKit/UIKit.h>

/* Okno logowania do Telegrama: klucze api_id / api_hash i numer telefonu -> kod -> (hasło 2FA). */
@interface ACSetupController : UIViewController <UITextFieldDelegate>
+ (void)presentFrom:(UIViewController *)host;
@end
