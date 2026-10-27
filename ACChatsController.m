#import "ACChatsController.h"
#import "ACChatController.h"
#import "ACDemo.h"
#import "ACTheme.h"
#import "ACViews.h"
#import "ACTelegram.h"

@implementation ACChatsController {
    UISearchBar *_search;
    NSString *_query;
    NSMutableArray *_chats;      /* widoczne czaty (po filtrze) */
    NSMutableArray *_snippets;   /* podgląd do pokazania w wierszu */
}

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
    _search = ACMakeSearchBar(self, @"Szukaj w czatach");
    self.tableView.tableHeaderView = _search;
    _query = @"";
    [self applyFilter];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(dataChanged:) name:ACTGChatsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(dataChanged:) name:ACTGStateDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)dataChanged:(NSNotification *)n
{
    [self applyFilter];
    [self.tableView reloadData];
    NSString *st = [ACTelegram shared].statusText;
    self.title = [st length] ? st : @"Czaty";
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)applyFilter
{
    _chats = [NSMutableArray array];
    _snippets = [NSMutableArray array];
    for (ACChat *c in [ACDemo chats]) {
        NSString *snip = nil;
        if ([c matchesQuery:_query snippet:&snip]) {
            [_chats addObject:c];
            [_snippets addObject:snip ? snip : @""];
        }
    }
}

/* ---- wyszukiwanie ---- */

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

/* ---- tabela ---- */

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    return [_chats count] ? (NSInteger)[_chats count] : 1;     /* 1 = wiersz "brak wyników" */
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    if ([_chats count] == 0) {
        ACCell *empty = [ACCell cellForTable:tv identifier:@"empty"];
        empty.imageView.image = nil;
        if ([_query length] == 0 && [ACTelegram shared].live) {
            NSString *st = [ACTelegram shared].statusText;
            empty.textLabel.text = [st length] ? st : @"Brak czatów";
            empty.detailTextLabel.text = [st length] ? @"Chwileczkę, pobieram rozmowy z Telegrama" : @"Napisz do kogoś w Telegramie, a rozmowa pojawi się tutaj";
        } else {
            empty.textLabel.text = @"Brak wyników";
            empty.detailTextLabel.text = [NSString stringWithFormat:@"Nic nie pasuje do „%@”", _query];
        }
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }
    ACChat *chat = [_chats objectAtIndex:(NSUInteger)ip.row];
    ACChatCell *cell = [ACChatCell chatCellForTable:tv];
    [cell configureWithName:chat.name preview:[_snippets objectAtIndex:(NSUInteger)ip.row] time:chat.lastTime unread:chat.unread];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    if ([_chats count] == 0) return;
    ACChat *chat = [_chats objectAtIndex:(NSUInteger)ip.row];
    chat.unread = 0;
    [[ACTelegram shared] markReadChat:chat];
    [_search resignFirstResponder];
    ACChatController *c = [[ACChatController alloc] initWithChat:chat];
    c.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:c animated:YES];
}

@end
