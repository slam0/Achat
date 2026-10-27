#import "ACChatController.h"
#import "ACTheme.h"
#import "ACViews.h"

#define BAR_H 46.0f

@implementation ACChatController {
    ACChat *_chat;
    UITableView *_table;
    UIView *_bar;
    UITextField *_field;
    UIButton *_send;
    CGFloat _kb;
}

- (id)initWithChat:(ACChat *)chat
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _chat = chat;
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
    CGRect b = self.view.bounds;
    UIView *bg = ACBackgroundView(b);
    [self.view addSubview:bg];

    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - BAR_H) style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.allowsSelection = NO;
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

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self scrollToBottomAnimated:NO];
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

- (void)scrollToBottomAnimated:(BOOL)animated
{
    NSInteger n = (NSInteger)[_chat.messages count];
    if (n == 0) return;
    [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:n - 1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (void)sendTapped
{
    NSString *t = [_field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t length] == 0) return;
    [_chat addMessage:t outgoing:YES];
    _field.text = @"";
    [_table reloadData];
    [self scrollToBottomAnimated:YES];
    ACChat *chat = _chat;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [chat addMessage:[ACDemo autoReplyFor:chat] outgoing:NO];
        if (self.isViewLoaded) {
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
    return (NSInteger)[_chat.messages count];
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip
{
    ACMessage *m = [_chat.messages objectAtIndex:(NSUInteger)ip.row];
    return [ACBubbleCell heightForText:m.text width:tv.bounds.size.width] + (ip.row == 0 ? 6.0f : 0.0f);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    ACMessage *m = [_chat.messages objectAtIndex:(NSUInteger)ip.row];
    ACBubbleCell *cell = [ACBubbleCell bubbleCellForTable:tv];
    [cell configureWithText:m.text time:m.time outgoing:m.outgoing];
    return cell;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv
{
    [_field resignFirstResponder];
}

@end
