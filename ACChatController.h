#import <UIKit/UIKit.h>
#import "ACDemo.h"

@interface ACChatController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
- (id)initWithChat:(ACChat *)chat;
@end
