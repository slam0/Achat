#import "ACContactsController.h"
#import "ACChatController.h"
#import "ACDemo.h"
#import "ACTheme.h"
#import "ACViews.h"
#import "ACTelegram.h"

@implementation ACContactsController {
    UISearchBar *_search;
    NSString *_query;
    NSMutableArray *_list;
}

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
    _search = ACMakeSearchBar(self, @"Szukaj kontaktów");
    self.tableView.tableHeaderView = _search;
    _query = @"";
    [self applyFilter];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dataChanged:) name:ACTGChatsDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)dataChanged:(NSNotification *)n
{
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)applyFilter
{
    _list = [NSMutableArray array];
    for (ACChat *c in [ACDemo chats]) {
        if (c.peerKind > 1) continue;    /* kontakty = rozmowy z osobami */
        if (ACTextMatches(c.name, _query) || ACTextMatches(c.status, _query)) [_list addObject:c];
    }
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text
{
    _query = [text copy];
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)sb { [sb setShowsCancelButton:YES animated:YES]; }

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }

- (void)searchBarCancelButtonClicked:(UISearchBar *)sb
{
    sb.text = @"";
    _query = @"";
    [sb setShowsCancelButton:NO animated:YES];
    [sb resignFirstResponder];
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv
{
    if ([_search isFirstResponder]) [_search resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    return [_list count] ? (NSInteger)[_list count] : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    ACCell *cell = [ACCell cellForTable:tv identifier:@"contact"];
    if ([_list count] == 0) {
        cell.imageView.image = nil;
        cell.textLabel.text = @"Brak wyników";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Nic nie pasuje do „%@”", _query];
        cell.detailTextLabel.textColor = ACSubtleColor();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    ACChat *chat = [_list objectAtIndex:(NSUInteger)ip.row];
    cell.imageView.image = ACAvatarImage(chat.name, 42.0f);
    cell.textLabel.text = chat.name;
    cell.detailTextLabel.text = chat.status;
    BOOL online = [chat.status isEqualToString:@"online"];
    cell.detailTextLabel.textColor = online ? [UIColor colorWithRed:0.1f green:0.55f blue:0.2f alpha:1] : ACSubtleColor();
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    if ([_list count] == 0) return;
    ACChat *chat = [_list objectAtIndex:(NSUInteger)ip.row];
    [_search resignFirstResponder];
    ACChatController *c = [[ACChatController alloc] initWithChat:chat];
    c.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:c animated:YES];
}

@end
