#import <UIKit/UIKit.h>
#import "ACDemo.h"

@interface ACChatController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UISearchBarDelegate>
- (id)initWithChat:(ACChat *)chat;
@end
