#import "ACContactsController.h"
#import "ACChatController.h"
#import "ACDemo.h"
#import "ACTheme.h"
#import "ACViews.h"

@implementation ACContactsController

- (id)init
{
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Kontakty";
    ACStyleTable(self.tableView);
    self.tableView.rowHeight = 58.0f;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    return (NSInteger)[[ACDemo chats] count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    ACChat *chat = [[ACDemo chats] objectAtIndex:(NSUInteger)ip.row];
    ACCell *cell = [ACCell cellForTable:tv identifier:@"contact"];
    cell.imageView.image = ACAvatarImage(chat.name, 42.0f);
    cell.textLabel.text = chat.name;
    cell.detailTextLabel.text = chat.status;
    BOOL online = [chat.status isEqualToString:@"online"];
    cell.detailTextLabel.textColor = online ? [UIColor colorWithRed:0.1f green:0.62f blue:0.2f alpha:1] : ACSubtleColor();
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    ACChat *chat = [[ACDemo chats] objectAtIndex:(NSUInteger)ip.row];
    ACChatController *c = [[ACChatController alloc] initWithChat:chat];
    c.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:c animated:YES];
}

@end
