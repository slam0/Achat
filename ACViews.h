#import <UIKit/UIKit.h>
#import "ACDemo.h"

/* Wspólne widoki: komórki z połyskiem (metal, szkło Aero, grafit), nagłówki sekcji, komórka czatu. */

@interface ACCell : UITableViewCell          /* podtytuł + błyszczące tło */
+ (ACCell *)cellForTable:(UITableView *)table identifier:(NSString *)ident;
@end

/* Wiersz listy czatów: szklana kula z inicjałami, tytuł, ostatnia wiadomość, godzina i licznik. */
@interface ACChatCell : ACCell
+ (ACChatCell *)chatCellForTable:(UITableView *)table;
- (void)configureWithName:(NSString *)name preview:(NSString *)preview time:(NSString *)time unread:(NSInteger)unread;
@end

/* Dymek wiadomości w rozmowie. */
@interface ACBubbleCell : UITableViewCell
+ (ACBubbleCell *)bubbleCellForTable:(UITableView *)table;
- (void)configureWithMessage:(ACMessage *)message;
+ (CGFloat)heightForMessage:(ACMessage *)message;
@end

UIView *ACHeaderForTitle(NSString *title);
