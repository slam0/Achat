#import "ACCallController.h"
#import "ACCall.h"
#import "ACTheme.h"

@implementation ACCallController {
    UIImageView *_avatar;
    UILabel *_name, *_status, *_hint;
    UIButton *_mute, *_speaker, *_hang, *_accept, *_decline;
    NSString *_avatarName;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)loadView
{
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
}

- (UILabel *)labelWithSize:(CGFloat)size bold:(BOOL)bold y:(CGFloat)y
{
    CGRect b = self.view.bounds;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, b.size.width - 32, size + 12)];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    l.backgroundColor = [UIColor clearColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.5f;
    return l;
}

- (UIButton *)buttonTitle:(NSString *)title style:(int)style action:(SEL)sel
{
    UIButton *b = ACGelButton(title, style, CGRectZero);
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18.0f];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    CGRect b = self.view.bounds;
    [self.view addSubview:ACBackgroundView(b)];

    _avatar = [[UIImageView alloc] initWithFrame:CGRectMake((b.size.width - 120) / 2, 60, 120, 120)];
    _avatar.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_avatar];

    _name = [self labelWithSize:28 bold:YES y:196];
    _name.textColor = ACP()->metal || ACP()->classic ? ACTextColor() : [UIColor whiteColor];
    ACStyleShadow(_name);
    [self.view addSubview:_name];
    _status = [self labelWithSize:17 bold:NO y:236];
    _status.numberOfLines = 0;                         /* komunikaty o błędach bywają długie */
    _status.adjustsFontSizeToFitWidth = NO;
    _status.frame = CGRectMake(16, 236, b.size.width - 32, 110);
    _status.lineBreakMode = NSLineBreakByWordWrapping;
    _status.textAlignment = NSTextAlignmentCenter;
    _status.textColor = ACP()->metal || ACP()->classic ? ACSubtleColor() : [UIColor colorWithWhite:1.0f alpha:0.9f];
    ACStyleShadow(_status);
    [self.view addSubview:_status];

    _mute = [self buttonTitle:@"Wycisz" style:1 action:@selector(muteTapped)];
    _speaker = [self buttonTitle:@"Głośnik" style:1 action:@selector(speakerTapped)];
    _hang = [self buttonTitle:@"Zakończ" style:2 action:@selector(hangTapped)];
    _accept = [self buttonTitle:@"Odbierz" style:3 action:@selector(acceptTapped)];
    _decline = [self buttonTitle:@"Odrzuć" style:2 action:@selector(hangTapped)];
    [self layoutButtons];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callChanged:) name:ACCallDidChangeNotification object:nil];
    [self refresh];
}

- (void)layoutButtons
{
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width, bottom = b.size.height - 40;
    CGFloat half = (w - 16 * 3) / 2;
    _mute.frame = CGRectMake(16, bottom - 130, half, 50);
    _speaker.frame = CGRectMake(32 + half, bottom - 130, half, 50);
    _hang.frame = CGRectMake(16, bottom - 60, w - 32, 54);
    _accept.frame = CGRectMake(32 + half, bottom - 60, half, 54);
    _decline.frame = CGRectMake(16, bottom - 60, half, 54);
    for (UIButton *x in [NSArray arrayWithObjects:_mute, _speaker, _hang, _accept, _decline, nil])
        x.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
}

- (void)callChanged:(NSNotification *)n { [self refresh]; }

- (void)styleToggle:(UIButton *)b on:(BOOL)on title:(NSString *)title
{
    [b setBackgroundImage:ACGelImage(on ? 0 : 1) forState:UIControlStateNormal];
    [b setTitle:on ? [title stringByAppendingString:@" ✓"] : title forState:UIControlStateNormal];
}

- (void)refresh
{
    ACCall *c = [ACCall shared];
    if (!_name) return;
    NSString *nm = c.peerName ?: @"";
    _name.text = nm;
    if (![nm isEqualToString:_avatarName]) { _avatarName = nm; _avatar.image = ACAvatarImage(nm, 120); }
    _status.text = c.statusText;
    _status.font = [UIFont systemFontOfSize:[c.statusText rangeOfString:@"\n"].location != NSNotFound ? 12.0f : 17.0f];     /* linie diagnostyczne są drobniejsze */
    BOOL incoming = c.state == ACCallIncoming;
    BOOL ended = c.state == ACCallEnded || c.state == ACCallIdle;
    _accept.hidden = !incoming;
    _decline.hidden = !incoming;
    _hang.hidden = incoming || c.state == ACCallIdle;
    [_hang setTitle:c.state == ACCallEnded ? @"Zamknij" : @"Zakończ" forState:UIControlStateNormal];
    [_hang setBackgroundImage:ACGelImage(c.state == ACCallEnded ? 1 : 2) forState:UIControlStateNormal];
    _mute.hidden = incoming || ended;
    _speaker.hidden = incoming || ended;
    [self styleToggle:_mute on:c.muted title:@"Wycisz"];
    [self styleToggle:_speaker on:c.speaker title:@"Głośnik"];
}

- (void)muteTapped { [[ACCall shared] setMuted:![ACCall shared].muted]; }
- (void)speakerTapped { [[ACCall shared] setSpeaker:![ACCall shared].speaker]; }
- (void)hangTapped { [[ACCall shared] hangup]; }
- (void)acceptTapped { [[ACCall shared] accept]; }

- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return o == UIInterfaceOrientationPortrait; }

@end
