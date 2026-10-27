#import "ACChatController.h"
#import "ACTheme.h"
#import "ACViews.h"
#import "ACTelegram.h"
#import "ACCall.h"

#define BAR_H 46.0f

@implementation ACChatController {
    ACMedia *_wanted;                       /* załącznik, który otworzymy po pobraniu */
    UIDocumentInteractionController *_dic;
    int _alertAction;                       /* 1 = pobierz format spoza iOS 6, 2 = pobierz duży plik */
    ACMedia *_alertMedia;
    ACChat *_chat;
    UITableView *_table;
    UIView *_bar;
    UITextField *_field;
    UIButton *_send;
    CGFloat _kb;
    NSArray *_visible;          /* wiadomości na ekranie (wszystkie albo wyniki wyszukiwania) */
    UISearchBar *_search;
    NSString *_query;
    BOOL _searching;
    BOOL _appeared;
}

- (id)initWithChat:(ACChat *)chat
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _chat = chat;
        _query = @"";
        _visible = [chat.messages copy];
        self.title = chat.name;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView
{
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self updateBarButtons];
    CGRect b = self.view.bounds;
    UIView *bg = ACBackgroundView(b);
    [self.view addSubview:bg];

    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - BAR_H) style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.allowsSelection = YES;
    [self.view addSubview:_table];

    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - BAR_H, b.size.width, BAR_H)];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UIImageView *barBg = [[UIImageView alloc] initWithFrame:_bar.bounds];
    barBg.image = ACInputBarImage();
    barBg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_bar addSubview:barBg];

    _send = ACGelButton(@"Wyślij", 0, CGRectMake(b.size.width - 78, 7, 70, 32));
    _send.titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];
    _send.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_send addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_send];

    UIImageView *fieldBg = [[UIImageView alloc] initWithFrame:CGRectMake(8, 7, b.size.width - 8 - 86, 32)];
    fieldBg.image = ACInputFieldImage();
    fieldBg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_bar addSubview:fieldBg];
    _field = [[UITextField alloc] initWithFrame:CGRectMake(18, 7, b.size.width - 18 - 94, 32)];
    _field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _field.font = [UIFont systemFontOfSize:16.0f];
    _field.textColor = ACRGB(ACP()->fieldText, 1);
    _field.placeholder = @"Napisz wiadomość…";
    _field.returnKeyType = UIReturnKeySend;
    _field.enablesReturnKeyAutomatically = YES;
    _field.autocorrectionType = UITextAutocorrectionTypeDefault;
    _field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _field.delegate = self;
    [_bar addSubview:_field];
    [self.view addSubview:_bar];

    if (_chat.peerKind != 0 && !_chat.canWrite) {
        _field.enabled = NO;
        _field.placeholder = @"Tylko do odczytu";
        _send.enabled = NO;
    }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(telegramChanged:) name:ACTGChatsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(mediaChanged:) name:ACTGMediaDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
}

/* "Szukaj" zawsze; w czacie z użytkownikiem dodatkowo przycisk rozmowy */
- (void)updateBarButtons
{
    UIBarButtonItem *search = ACBarButton(@"Szukaj", self, @selector(toggleSearch));
    if (_chat.peerKind == 1 && [ACTelegram shared].live) {
        UIBarButtonItem *call = ACBarButton(@"☎", self, @selector(callTapped));
        self.navigationItem.rightBarButtonItems = [NSArray arrayWithObjects:search, call, nil];
    } else {
        self.navigationItem.rightBarButtonItems = [NSArray arrayWithObject:search];
    }
}

- (void)callTapped
{
    [_field resignFirstResponder];
    NSString *err = [[ACCall shared] startCallWithChat:_chat];
    if (err) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Rozmowa" message:err delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [a show];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self scrollToBottomAnimated:NO];
    _appeared = YES;
    if (_chat.peerKind != 0) {
        if (!_chat.historyLoaded) [[ACTelegram shared] loadHistoryForChat:_chat];
        [[ACTelegram shared] markReadChat:_chat];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    _appeared = NO;
}

/* nowe wiadomości, historia i potwierdzenia z Telegrama */
- (void)telegramChanged:(NSNotification *)n
{
    ACChat *c = [[n userInfo] objectForKey:@"chat"];
    if (c && c != _chat) return;
    if (!self.isViewLoaded) return;
    BOOL wasAtBottom = YES;
    if (_table.contentSize.height > _table.bounds.size.height) {
        wasAtBottom = _table.contentOffset.y + _table.bounds.size.height >= _table.contentSize.height - 80.0f;
    }
    [self rebuildVisible];
    [_table reloadData];
    if (wasAtBottom) [self scrollToBottomAnimated:_appeared];
    if (_appeared && _chat.unread > 0) [[ACTelegram shared] markReadChat:_chat];
}

- (void)relayout
{
    CGRect b = self.view.bounds;
    CGFloat barY = b.size.height - BAR_H - _kb;
    _bar.frame = CGRectMake(0, barY, b.size.width, BAR_H);
    _table.frame = CGRectMake(0, 0, b.size.width, barY);
}

- (void)keyboardWillChange:(NSNotification *)n
{
    NSDictionary *info = [n userInfo];
    CGRect kb = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    BOOL show = [[n name] isEqualToString:UIKeyboardWillShowNotification];
    _kb = show ? kb.size.height : 0.0f;
    NSTimeInterval dur = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:dur animations:^{
        [self relayout];
    } completion:^(BOOL f) { [self scrollToBottomAnimated:YES]; }];
}

/* ---- wyszukiwanie w rozmowie ---- */

- (void)rebuildVisible
{
    if (!_searching || [_query length] == 0) {
        _visible = [_chat.messages copy];
    } else {
        NSMutableArray *hits = [NSMutableArray array];
        for (ACMessage *m in _chat.messages) {
            if (ACTextMatches([m summary], _query)) [hits addObject:m];
        }
        _visible = hits;
    }
    if (_searching && [_query length]) self.title = [NSString stringWithFormat:@"Znaleziono: %lu", (unsigned long)[_visible count]];
    else self.title = _chat.name;
}

- (void)toggleSearch
{
    if (_searching) { [self endSearch]; return; }
    _searching = YES;
    _query = @"";
    _search = ACMakeSearchBar(self, @"Szukaj w rozmowie");
    _table.tableHeaderView = _search;
    self.navigationItem.rightBarButtonItems = [NSArray arrayWithObject:ACBarButton(@"Gotowe", self, @selector(toggleSearch))];
    [self rebuildVisible];
    [_table reloadData];
    [_table setContentOffset:CGPointZero animated:NO];
    [_search becomeFirstResponder];
}

- (void)endSearch
{
    _searching = NO;
    _query = @"";
    [_search resignFirstResponder];
    _table.tableHeaderView = nil;
    _search = nil;
    [self updateBarButtons];
    [self rebuildVisible];
    [_table reloadData];
    [self scrollToBottomAnimated:NO];
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text
{
    _query = [text copy];
    [self rebuildVisible];
    [_table reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }

- (void)scrollToBottomAnimated:(BOOL)animated
{
    if (_searching) return;
    NSInteger n = (NSInteger)[_visible count];
    if (n == 0) return;
    [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:n - 1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (void)sendTapped
{
    NSString *t = [_field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t length] == 0) return;
    if (_searching) [self endSearch];
    _field.text = @"";
    if (_chat.peerKind != 0) {
        [[ACTelegram shared] sendText:t toChat:_chat];       /* dodaje dymek i powiadamia o zmianie */
        return;
    }
    [_chat addMessage:t outgoing:YES];
    [self rebuildVisible];
    [_table reloadData];
    [self scrollToBottomAnimated:YES];
    ACChat *chat = _chat;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [chat addMessage:[ACDemo autoReplyFor:chat] outgoing:NO];
        if (self.isViewLoaded) {
            [self rebuildVisible];
            [_table reloadData];
            [self scrollToBottomAnimated:YES];
        }
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf
{
    [self sendTapped];
    return NO;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    return (NSInteger)[_visible count];
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip
{
    ACMessage *m = [_visible objectAtIndex:(NSUInteger)ip.row];
    return [ACBubbleCell heightForMessage:m] + (ip.row == 0 ? 6.0f : 0.0f);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    ACMessage *m = [_visible objectAtIndex:(NSUInteger)ip.row];
    if (m.media) [[ACTelegram shared] loadThumb:m.media];
    ACBubbleCell *cell = [ACBubbleCell bubbleCellForTable:tv];
    [cell configureWithMessage:m];
    return cell;
}

/* ---- załączniki ---- */

- (NSIndexPath *)tableView:(UITableView *)tv willSelectRowAtIndexPath:(NSIndexPath *)ip
{
    ACMessage *m = [_visible objectAtIndex:(NSUInteger)ip.row];
    return (m.media && [m.media canOpen]) ? ip : nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    ACMedia *md = ((ACMessage *)[_visible objectAtIndex:(NSUInteger)ip.row]).media;
    if (!md || ![md canOpen] || md.state == ACMediaLoading) return;
    [_field resignFirstResponder];
    if (md.state == ACMediaDone && [md.localPath length] && [[NSFileManager defaultManager] fileExistsAtPath:md.localPath]) {
        [self openFile:md.localPath mode:[md needsOtherApp] ? 2 : 1];
        return;
    }
    if ([md needsOtherApp]) {
        _alertAction = 1;
        _alertMedia = md;
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Format spoza iOS 6"
            message:@"iOS 6 nie odtworzy tego pliku sam. Mogę go pobrać i otworzyć w innej aplikacji, jeśli masz na telefonie odpowiednią."
            delegate:self cancelButtonTitle:@"Anuluj" otherButtonTitles:@"Pobierz", nil];
        [a show];
        return;
    }
    if (md.size > 25 * 1024 * 1024) {
        _alertAction = 2;
        _alertMedia = md;
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Duży plik"
            message:[NSString stringWithFormat:@"Plik ma %@. Pobrać go teraz?", [ACMedia sizeString:md.size]]
            delegate:self cancelButtonTitle:@"Anuluj" otherButtonTitles:@"Pobierz", nil];
        [a show];
        return;
    }
    [self startDownload:md];
}

- (void)startDownload:(ACMedia *)md
{
    _wanted = md;
    [[ACTelegram shared] downloadMedia:md openMode:[md needsOtherApp] ? 2 : 1];
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)i
{
    ACMedia *md = _alertMedia;
    int act = _alertAction;
    _alertMedia = nil;
    _alertAction = 0;
    if (act != 0 && md && i == 1) [self startDownload:md];
}

- (void)openFile:(NSString *)path mode:(int)mode
{
    [_field resignFirstResponder];
    _dic = [UIDocumentInteractionController interactionControllerWithURL:[NSURL fileURLWithPath:path]];
    _dic.delegate = self;
    BOOL ok = NO;
    if (mode == 1) ok = [_dic presentPreviewAnimated:YES];
    if (!ok) ok = [_dic presentOpenInMenuFromRect:self.view.bounds inView:self.view animated:YES];
    if (!ok) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Nie można otworzyć pliku"
            message:@"Na tym telefonie nie ma aplikacji, która obsłuży ten typ pliku."
            delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [a show];
    }
}

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller
{
    return self.navigationController ? self.navigationController : self;
}

/* postęp i koniec pobierania: odświeżamy widoczne dymki, a po pobraniu otwieramy plik */
- (void)mediaChanged:(NSNotification *)n
{
    ACMedia *md = [[n userInfo] objectForKey:@"media"];
    if (!md || !self.isViewLoaded) return;
    BOOL relayout = [[[n userInfo] objectForKey:@"relayout"] boolValue];
    if (relayout) {
        [_table reloadData];
    } else {
        for (NSIndexPath *ip in [_table indexPathsForVisibleRows]) {
            if ((NSUInteger)ip.row >= [_visible count]) continue;
            ACMessage *m = [_visible objectAtIndex:(NSUInteger)ip.row];
            if (m.media != md) continue;
            ACBubbleCell *cell = (ACBubbleCell *)[_table cellForRowAtIndexPath:ip];
            if (cell) [cell configureWithMessage:m];
        }
    }
    if (md != _wanted) return;
    if (md.state == ACMediaDone) {
        _wanted = nil;
        int mode = md.openMode;
        md.openMode = 0;
        if (_appeared && mode != 0 && [md.localPath length]) [self openFile:md.localPath mode:mode];
    } else if (md.state == ACMediaFailed) {
        _wanted = nil;
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Nie udało się pobrać"
            message:[md.error length] ? md.error : @"Spróbuj jeszcze raz."
            delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [a show];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv
{
    [_field resignFirstResponder];
    [_search resignFirstResponder];
}

@end
