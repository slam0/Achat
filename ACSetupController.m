#import "ACSetupController.h"
#import "ACSlideView.h"
#import "ACTelegram.h"
#import "ACStore.h"
#import "ACTheme.h"

static UIFont *Light(CGFloat size)
{
    UIFont *f = [UIFont fontWithName:@"HelveticaNeue-Light" size:size];
    return f ? f : [UIFont systemFontOfSize:size];
}

static UILabel *ShadowLabel(CGRect frame, NSString *text, UIFont *font, UIColor *color, NSTextAlignment align)
{
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.backgroundColor = [UIColor clearColor];
    l.numberOfLines = 0;
    l.font = font;
    l.textColor = color;
    l.text = text;
    l.textAlignment = align;
    l.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.55f];
    l.shadowOffset = CGSizeMake(0, -1);
    return l;
}

/* ===================== ekran powitalny / końcowy ===================== */

@interface ACSetupWelcomeController : UIViewController
@property (nonatomic) BOOL finished;
@end

@interface ACSetupFormController : UITableViewController <UITextFieldDelegate>
@end

@implementation ACSetupWelcomeController

- (void)loadView
{
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    CGRect b = self.view.bounds;
    [self.view addSubview:ACLinenBackgroundView(b)];
    CGFloat w = b.size.width, h = b.size.height;

    NSString *big = self.finished ? @"Gotowe" : @"AeroChat";
    UILabel *title = ShadowLabel(CGRectMake(10, h * 0.22f, w - 20, 90), big, Light(self.finished ? 64.0f : 62.0f), [UIColor whiteColor], NSTextAlignmentCenter);
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumFontSize = 30.0f;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:title];

    NSString *sub;
    if (self.finished) {
        NSString *n = [ACTelegram shared].userName;
        sub = [n length] ? [NSString stringWithFormat:@"Zalogowano jako %@.\nTwoje czaty pojawią się za chwilę.", n] : @"Zalogowano do Telegrama.\nTwoje czaty pojawią się za chwilę.";
    } else {
        sub = @"Telegram na iOS 6";
    }
    UILabel *sl = ShadowLabel(CGRectMake(20, h * 0.22f + 88, w - 40, 60), sub, [UIFont fontWithName:@"HelveticaNeue" size:18.0f] ? [UIFont fontWithName:@"HelveticaNeue" size:18.0f] : [UIFont systemFontOfSize:18.0f],
                              [UIColor colorWithWhite:0.86f alpha:1.0f], NSTextAlignmentCenter);
    sl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:sl];

    if (self.finished) {
        UIButton *go = ACGelButton(@"Zaczynamy", 0, CGRectMake(20, h - 96 + 20, w - 40, 52));
        go.titleLabel.font = [UIFont boldSystemFontOfSize:20.0f];
        go.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [go addTarget:self action:@selector(finishTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:go];
    } else {
        UIButton *skip = [UIButton buttonWithType:UIButtonTypeCustom];
        skip.frame = CGRectMake(40, h - 96 - 40, w - 80, 34);
        skip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [skip setTitle:@"Pomiń: zostań w trybie demo" forState:UIControlStateNormal];
        [skip setTitleColor:[UIColor colorWithWhite:0.80f alpha:1.0f] forState:UIControlStateNormal];
        [skip setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
        skip.titleLabel.font = [UIFont systemFontOfSize:15.0f];
        skip.titleLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.6f];
        skip.titleLabel.shadowOffset = CGSizeMake(0, -1);
        [skip addTarget:self action:@selector(skipTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:skip];

        ACSlideView *slide = [[ACSlideView alloc] initWithFrame:CGRectMake(0, h - 96, w, 96)];
        slide.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        slide.title = @"przesuń, aby skonfigurować";
        [slide addTarget:self action:@selector(slid) forControlEvents:UIControlEventValueChanged];
        [self.view addSubview:slide];
    }
}

- (void)slid
{
    ACSetupFormController *f = [[ACSetupFormController alloc] initWithStyle:UITableViewStyleGrouped];
    [self.navigationController pushViewController:f animated:YES];
}

- (void)skipTapped
{
    [[ACStore shared] setObject:[NSNumber numberWithBool:YES] forKey:@"setupSeen"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)finishTapped
{
    [[ACStore shared] setObject:[NSNumber numberWithBool:YES] forKey:@"setupSeen"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

/* ===================== formularz logowania ===================== */

@implementation ACSetupFormController {
    int _step;                        /* 0 numer, 1 kod, 2 hasło */
    NSString *_vApiId, *_vApiHash, *_vPhone, *_vCode, *_vPass;
    UITextField *_active;
    UIActivityIndicatorView *_spin;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Konfiguracja";
    self.tableView.backgroundView = ACLinenBackgroundView(self.tableView.bounds);
    self.tableView.backgroundColor = [UIColor clearColor];
    ACTelegram *tg = [ACTelegram shared];
    _vApiId = tg.apiId > 0 && !tg.builtInKeys ? [NSString stringWithFormat:@"%d", tg.apiId] : @"";
    _vApiHash = tg.builtInKeys ? @"" : tg.apiHash;
    _vPhone = tg.phone ? [@"+" stringByAppendingString:tg.phone] : @"";
    _vCode = @"";
    _vPass = @"";
    _step = [self stepForState];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged:) name:ACTGStateDidChangeNotification object:nil];
    [self refreshChrome];
}

- (int)stepForState
{
    ACTGState s = [ACTelegram shared].state;
    return s == ACTGStateNeedCode ? 1 : (s == ACTGStateNeedPassword ? 2 : 0);
}

/* ---------- nagłówek, stopka, pasek ---------- */

- (UIView *)headerForStep
{
    NSString *t = _step == 0 ? @"Wpisz swój numer telefonu" : (_step == 1 ? @"Wpisz kod" : @"Hasło dwuskładnikowe");
    UILabel *l = ShadowLabel(CGRectMake(20, 18, 280, 30), t, [UIFont boldSystemFontOfSize:20.0f], [UIColor whiteColor], NSTextAlignmentCenter);
    l.numberOfLines = 1;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 58)];
    [v addSubview:l];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    return v;
}

- (NSString *)footerText
{
    ACTelegram *tg = [ACTelegram shared];
    if (_step == 0) return tg.builtInKeys ? @"Telegram wyśle kod potwierdzający SMS-em albo do aplikacji Telegram na innym Twoim urządzeniu. Numer podaj z numerem kraju (9 cyfr bez kierunkowego to numer polski, +48)."
                                          : @"Telegram wyśle kod SMS-em albo do aplikacji Telegram na innym urządzeniu. Numer podaj z numerem kraju (9 cyfr to numer polski, +48).";
    if (_step == 1) return [NSString stringWithFormat:@"%@\nNumer: +%@", [tg.codeInfo length] ? tg.codeInfo : @"Kod został wysłany.", tg.phone ? tg.phone : @""];
    NSString *h = [tg.passwordHint length] ? [NSString stringWithFormat:@"To konto ma dodatkowe hasło. Podpowiedź: %@\n", tg.passwordHint] : @"To konto ma dodatkowe hasło.\n";
    return [h stringByAppendingString:@"Sprawdzanie hasła na starszym iPhonie może potrwać kilka sekund."];
}

- (UIView *)footerForState
{
    ACTelegram *tg = [ACTelegram shared];
    UIFont *f = [UIFont systemFontOfSize:14.0f];
    CGFloat w = 280.0f;
    NSString *t = [self footerText];
    CGSize sz = [t sizeWithFont:f constrainedToSize:CGSizeMake(w, 1000) lineBreakMode:NSLineBreakByWordWrapping];
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 0)];
    UILabel *l = ShadowLabel(CGRectMake(20, 10, w, sz.height), t, f, [UIColor colorWithWhite:0.88f alpha:1.0f], NSTextAlignmentCenter);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    CGFloat y = 10 + sz.height + 10;
    NSString *err = tg.busy ? nil : tg.lastError;
    if ([err length]) {
        CGSize es = [err sizeWithFont:[UIFont boldSystemFontOfSize:14.0f] constrainedToSize:CGSizeMake(w, 1000) lineBreakMode:NSLineBreakByWordWrapping];
        UILabel *e = ShadowLabel(CGRectMake(20, y, w, es.height), err, [UIFont boldSystemFontOfSize:14.0f], [UIColor colorWithRed:1.0f green:0.55f blue:0.50f alpha:1.0f], NSTextAlignmentCenter);
        e.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [v addSubview:e];
        y += es.height + 10;
    }
    if (tg.busy) {
        NSString *bt = _step == 2 ? @"Sprawdzanie hasła…" : (tg.state == ACTGStateConnecting ? @"Łączenie z Telegramem…" : @"Chwileczkę…");
        UILabel *b = ShadowLabel(CGRectMake(20, y, w, 20), bt, [UIFont boldSystemFontOfSize:14.0f], [UIColor whiteColor], NSTextAlignmentCenter);
        b.numberOfLines = 1;
        b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [v addSubview:b];
        y += 30;
    }
    CGRect fr = v.frame;
    fr.size.height = y + 20;
    v.frame = fr;
    return v;
}

- (void)refreshChrome
{
    ACTelegram *tg = [ACTelegram shared];
    self.tableView.tableHeaderView = [self headerForStep];
    self.tableView.tableFooterView = [self footerForState];
    NSString *next = _step == 0 ? @"Dalej" : @"Zaloguj";
    if (tg.busy) {
        if (!_spin) _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        [_spin startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_spin];
    } else {
        self.navigationItem.rightBarButtonItem = ACBarButton(next, self, @selector(nextTapped));
    }
    if (_step > 0) {
        self.navigationItem.hidesBackButton = YES;
        self.navigationItem.leftBarButtonItem = tg.busy ? nil : ACBarButton(@"Zmień numer", self, @selector(changeNumberTapped));
    } else {
        self.navigationItem.hidesBackButton = NO;
        self.navigationItem.leftBarButtonItem = nil;
    }
}

- (void)stateChanged:(NSNotification *)n
{
    ACTelegram *tg = [ACTelegram shared];
    if (tg.state == ACTGStateReady && tg.authorized) {
        [self.view endEditing:YES];
        ACSetupWelcomeController *done = [[ACSetupWelcomeController alloc] init];
        done.finished = YES;
        [self.navigationController setViewControllers:[NSArray arrayWithObject:done] animated:YES];
        return;
    }
    int step = [self stepForState];
    if (step != _step) {
        _step = step;
        [self.tableView reloadData];
        [self refreshChrome];
        UITextField *f = nil;
        (void)f;
    } else {
        [self refreshChrome];
    }
}

/* ---------- tabela ---------- */

- (BOOL)showsKeys { return _step == 0 && ![ACTelegram shared].builtInKeys; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv
{
    if (_step == 0) return [self showsKeys] ? 2 : 1;
    if (_step == 1) return 2;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    if (_step == 0 && s == 1) return 2;
    if (_step == 1 && s == 1) return 1;
    return 1;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s
{
    if (_step == 0 && s == 1) {
        UILabel *l = ShadowLabel(CGRectMake(20, 8, 280, 22), @"Klucze aplikacji z my.telegram.org", [UIFont boldSystemFontOfSize:16.0f], [UIColor whiteColor], NSTextAlignmentLeft);
        l.numberOfLines = 1;
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 34)];
        [v addSubview:l];
        return v;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s
{
    return (_step == 0 && s == 1) ? 36.0f : 8.0f;
}

- (UITextField *)fieldInCell:(UITableViewCell *)cell placeholder:(NSString *)ph text:(NSString *)text tag:(int)tag
{
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(108, 0, 300 - 108 - 12, 44)];
    f.font = [UIFont systemFontOfSize:17.0f];
    f.textColor = [UIColor colorWithRed:0.22f green:0.33f blue:0.53f alpha:1.0f];
    f.placeholder = ph;
    f.text = text;
    f.tag = tag;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    f.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    f.delegate = self;
    [f addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [cell.contentView addSubview:f];
    return f;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0f];
    if (_step == 0 && ip.section == 0) {
        cell.textLabel.text = @"Numer";
        UITextField *f = [self fieldInCell:cell placeholder:@"+48 600 123 456" text:_vPhone tag:3];
        f.keyboardType = UIKeyboardTypePhonePad;
    } else if (_step == 0) {
        if (ip.row == 0) {
            cell.textLabel.text = @"api_id";
            UITextField *f = [self fieldInCell:cell placeholder:@"np. 1234567" text:_vApiId tag:1];
            f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        } else {
            cell.textLabel.text = @"api_hash";
            [self fieldInCell:cell placeholder:@"32 znaki" text:_vApiHash tag:2];
        }
    } else if (_step == 1 && ip.section == 0) {
        cell.textLabel.text = @"Kod";
        UITextField *f = [self fieldInCell:cell placeholder:@"12345" text:_vCode tag:4];
        f.keyboardType = UIKeyboardTypeNumberPad;
    } else if (_step == 1) {
        cell.textLabel.text = @"Wyślij kod ponownie";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor colorWithRed:0.22f green:0.33f blue:0.53f alpha:1.0f];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    } else {
        cell.textLabel.text = @"Hasło";
        UITextField *f = [self fieldInCell:cell placeholder:@"wpisz hasło" text:_vPass tag:5];
        f.secureTextEntry = YES;
        f.returnKeyType = UIReturnKeyGo;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_step == 1 && ip.section == 1) [[ACTelegram shared] resendCode];
}

/* ---------- pola ---------- */

- (void)fieldChanged:(UITextField *)f
{
    NSString *t = f.text ? f.text : @"";
    switch (f.tag) {
        case 1: _vApiId = t; break;
        case 2: _vApiHash = t; break;
        case 3: _vPhone = t; break;
        case 4: _vCode = t; break;
        case 5: _vPass = t; break;
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf
{
    if (tf.tag == 5) { [self nextTapped]; return NO; }
    [tf resignFirstResponder];
    return NO;
}

/* ---------- przyciski ---------- */

- (void)nextTapped
{
    [self.view endEditing:YES];
    ACTelegram *tg = [ACTelegram shared];
    if (tg.busy) return;
    if (_step == 0) {
        if (!tg.builtInKeys) {
            NSString *idText = [_vApiId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *hash = [_vApiHash stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([idText intValue] <= 0 || [hash length] < 16) {
                UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Brak kluczy" message:@"Ta kopia aplikacji nie ma wbudowanych kluczy. Wpisz api_id (liczba) i api_hash (32 znaki) z my.telegram.org." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                [a show];
                return;
            }
            [tg saveApiId:[idText intValue] apiHash:hash];
        }
        [tg startLoginWithPhone:_vPhone];
    } else if (_step == 1) {
        [tg submitCode:_vCode];
    } else {
        [tg submitPassword:_vPass];
    }
}

- (void)changeNumberTapped
{
    [self.view endEditing:YES];
    [[ACTelegram shared] cancelLogin];
}

@end

/* ===================== wejście ===================== */

@implementation ACSetupController

+ (void)presentFrom:(UIViewController *)host
{
    ACSetupWelcomeController *w = [[ACSetupWelcomeController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:w];
    ACStyleNavigationBar(nav.navigationBar);
    nav.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    ACTelegram *tg = [ACTelegram shared];
    if (tg.state == ACTGStateNeedCode || tg.state == ACTGStateNeedPassword) {
        /* logowanie było w toku (np. użytkownik odebrał kod w innej aplikacji): od razu formularz */
        ACSetupFormController *f = [[ACSetupFormController alloc] initWithStyle:UITableViewStyleGrouped];
        [nav setViewControllers:[NSArray arrayWithObjects:w, f, nil]];
    }
    [host presentViewController:nav animated:YES completion:nil];
}

@end
