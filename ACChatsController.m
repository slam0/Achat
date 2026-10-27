#import "ACChatsController.h"
#import "ACChatController.h"
#import "ACDemo.h"
#import "ACTheme.h"
#import "ACViews.h"

@implementation ACChatsController

- (id)init
{
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Czaty";
    ACStyleTable(self.tableView);
    self.tableView.rowHeight = 66.0f;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    return (NSInteger)[[ACDemo chats] count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    ACChat *chat = [[ACDemo chats] objectAtIndex:(NSUInteger)ip.row];
    ACChatCell *cell = [ACChatCell chatCellForTable:tv];
    [cell configureWithName:chat.name preview:chat.preview time:chat.lastTime unread:chat.unread];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    ACChat *chat = [[ACDemo chats] objectAtIndex:(NSUInteger)ip.row];
    chat.unread = 0;
    ACChatController *c = [[ACChatController alloc] initWithChat:chat];
    c.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:c animated:YES];
}

@end
