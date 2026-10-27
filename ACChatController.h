#import <UIKit/UIKit.h>
#import "ACDemo.h"

@interface ACChatController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UISearchBarDelegate, UIAlertViewDelegate, UIDocumentInteractionControllerDelegate>
- (id)initWithChat:(ACChat *)chat;
@end
