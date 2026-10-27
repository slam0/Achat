#import "ACSetupController.h"
#import "ACTelegram.h"
#import "ACStore.h"
#import "ACTheme.h"

#define MARGIN 16.0f
#define FIELD_H 38.0f

@implementation ACSetupController {
    UIScrollView *_scroll;
    int _step;                       /* 0 numer i klucze, 1 kod, 2 hasło */
    BOOL _built;
    UITextField *_fApiId, *_fApiHash, *_fPhone, *_fCode, *_fPass;
    UILabel *_errLabel, *_busyLabel;
    UIActivityIndicatorView *_spin;
    NSMutableArray *_buttons;        /* przyciski wyłączane podczas pracy */
    NSString *_vApiId, *_vApiHash, *_vPhone;
}

+ (void)presentFrom:(UIViewController *)host
{
    ACSetupController *c = [[ACSetupController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:c];
    ACStyleNavigationBar(nav.navigationBar);
    [host presentViewController:nav animated:YES completion:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

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
    self.title = @"Telegram";
    self.navigationItem.leftBarButtonItem = ACBarButton(@"Zamknij", self, @selector(closeTapped));
    CGRect b = self.view.bounds;
    [self.view addSubview:ACBackgroundView(b)];
    _scroll = [[UIScrollView alloc] initWithFrame:b];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scroll];

    ACTelegram *tg = [ACTelegram shared];
    _vApiId = tg.apiId > 0 ? [NSString stringWithFormat:@"%d", tg.apiId] : @"";
    _vApiHash = tg.apiHash;
    _vPhone = tg.phone ? [@"+" stringByAppendingString:tg.phone] : @"";
    _step = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged:) name:ACTGStateDidChangeNotification object:nil];
    [self update];
}

- (void)closeTapped
{
    [self.view endEditing:YES];
    ACTelegram *tg = [ACTelegram shared];
    if (!tg.authorized && tg.state != ACTGStateOffline && !tg.busy) [tg cancelLogin];
    [[ACStore shared] setObject:[NSNumber numberWithBool:YES] forKey:@"setupSeen"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)stateChanged:(NSNotification *)n { [self update]; }

- (int)currentStep
{
    ACTGState s = [ACTelegram shared].state;
    if (s == ACTGStateNeedCode) return 1;
    if (s == ACTGStateNeedPassword) return 2;
    return 0;
}

/* ---------- budowanie elementów ---------- */

- (UILabel *)labelAt:(CGFloat *)y text:(NSString *)text font:(UIFont *)font color:(UIColor *)color
{
    CGFloat w = _scroll.bounds.size.width - 2 * MARGIN;
    CGSize sz = [text sizeWithFont:font constrainedToSize:CGSizeMake(w, 2000) lineBreakMode:NSLineBreakByWordWrapping];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(MARGIN, *y, w, sz.height)];
    l.backgroundColor = [UIColor clearColor];
    l.numberOfLines = 0;
    l.font = font;
    l.textColor = color;
    l.text = text;
    [_scroll addSubview:l];
    *y += sz.height + 8.0f;
    return l;
}

- (UITextField *)fieldAt:(CGFloat *)y caption:(NSString *)caption placeholder:(NSString *)ph text:(NSString *)text
{
    [self labelAt:y text:caption font:[UIFont boldSystemFontOfSize:13.0f] color:ACSubtleColor()];
    *y -= 4.0f;
    CGFloat w = _scroll.bounds.size.width - 2 * MARGIN;
    UIImageView *bg = [[UIImageView alloc] initWithFrame:CGRectMake(MARGIN, *y, w, FIELD_H)];
    bg.image = ACInputFieldImage();
    [_scroll addSubview:bg];
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(MARGIN + 10, *y, w - 20, FIELD_H)];
    f.font = [UIFont systemFontOfSize:16.0f];
    f.textColor = ACRGB(ACP()->fieldText, 1);
    f.placeholder = ph;
    f.text = text;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    f.delegate = self;
    [_scroll addSubview:f];
    *y += FIELD_H + 12.0f;
    return f;
}

- (UIButton *)buttonAt:(CGFloat *)y title:(NSString *)title style:(int)style action:(SEL)action
{
    CGFloat w = _scroll.bounds.size.width - 2 * MARGIN;
    UIButton *b = ACGelButton(title, style, CGRectMake(MARGIN, *y, w, 42.0f));
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16.0f];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:b];
    [_buttons addObject:b];
    *y += 42.0f + 10.0f;
    return b;
}

- (void)captureValues
{
    if (_fApiId) _vApiId = _fApiId.text;
    if (_fApiHash) _vApiHash = _fApiHash.text;
    if (_fPhone) _vPhone = _fPhone.text;
}

- (void)rebuild
{
    [self captureValues];
    [_scroll.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    _fApiId = _fApiHash = _fPhone = _fCode = _fPass = nil;
    _buttons = [NSMutableArray array];
    ACTelegram *tg = [ACTelegram shared];
    CGFloat y = 14.0f;
    UIFont *small = [UIFont systemFontOfSize:13.0f];
    if (_step == 0) {
        [self labelAt:&y text:@"Połącz z Telegramem" font:[UIFont boldSystemFontOfSize:20.0f] color:ACTextColor()];
        [self labelAt:&y text:@"AeroChat łączy się z Telegramem własnym klientem, więc potrzebuje Twoich kluczy aplikacji. Wejdź na my.telegram.org (np. w Safari), zaloguj się swoim numerem, wybierz „API development tools” i utwórz aplikację. Przepisz stąd api_id i api_hash."
                 font:small color:ACSubtleColor()];
        _fApiId = [self fieldAt:&y caption:@"api_id" placeholder:@"np. 1234567" text:_vApiId];
        _fApiId.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        _fApiId.returnKeyType = UIReturnKeyNext;
        _fApiHash = [self fieldAt:&y caption:@"api_hash" placeholder:@"32 znaki" text:_vApiHash];
        _fApiHash.returnKeyType = UIReturnKeyNext;
        _fPhone = [self fieldAt:&y caption:@"Numer telefonu" placeholder:@"+48 600 123 456" text:_vPhone];
        _fPhone.keyboardType = UIKeyboardTypePhonePad;
    } else if (_step == 1) {
        [self labelAt:&y text:@"Wpisz kod" font:[UIFont boldSystemFontOfSize:20.0f] color:ACTextColor()];
        NSString *info = [tg.codeInfo length] ? tg.codeInfo : @"Kod został wysłany.";
        [self labelAt:&y text:[NSString stringWithFormat:@"%@\nNumer: +%@", info, tg.phone ? tg.phone : @""] font:small color:ACSubtleColor()];
        _fCode = [self fieldAt:&y caption:@"Kod" placeholder:@"12345" text:@""];
        _fCode.keyboardType = UIKeyboardTypeNumberPad;
    } else {
        [self labelAt:&y text:@"Hasło dwuskładnikowe" font:[UIFont boldSystemFontOfSize:20.0f] color:ACTextColor()];
        NSString *hint = [tg.passwordHint length] ? [NSString stringWithFormat:@"To konto ma dodatkowe hasło. Podpowiedź: %@", tg.passwordHint] : @"To konto ma dodatkowe hasło.";
        [self labelAt:&y text:hint font:small color:ACSubtleColor()];
        _fPass = [self fieldAt:&y caption:@"Hasło" placeholder:@"hasło" text:@""];
        _fPass.secureTextEntry = YES;
        _fPass.returnKeyType = UIReturnKeyGo;
    }
    _errLabel = [self labelAt:&y text:@" " font:[UIFont boldSystemFontOfSize:13.0f] color:ACRGB(ACP()->danger, 1)];
    _errLabel.frame = CGRectMake(MARGIN, _errLabel.frame.origin.y, _errLabel.frame.size.width, 60.0f);
    y += 52.0f;
    if (_step == 0) {
        [self buttonAt:&y title:@"Wyślij kod" style:0 action:@selector(sendCodeTapped)];
        [self buttonAt:&y title:@"Pomiń: zostań w trybie demo" style:1 action:@selector(closeTapped)];
    } else if (_step == 1) {
        [self buttonAt:&y title:@"Zaloguj" style:0 action:@selector(signInTapped)];
        [self buttonAt:&y title:@"Wyślij kod ponownie" style:1 action:@selector(resendTapped)];
        [self buttonAt:&y title:@"Zmień numer" style:1 action:@selector(backTapped)];
    } else {
        [self buttonAt:&y title:@"Zaloguj" style:0 action:@selector(passwordTapped)];
        [self labelAt:&y text:@"Sprawdzanie hasła na starszym iPhonie może potrwać kilka sekund." font:small color:ACSubtleColor()];
        [self buttonAt:&y title:@"Anuluj" style:1 action:@selector(backTapped)];
    }
    /* wskaźnik pracy tuż nad błędem */
    _spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:ACSpinnerStyle()];
    _spin.hidesWhenStopped = YES;
    _spin.frame = CGRectMake(MARGIN, _errLabel.frame.origin.y + 2.0f, 20, 20);
    [_scroll addSubview:_spin];
    _busyLabel = [[UILabel alloc] initWithFrame:CGRectMake(MARGIN + 28.0f, _errLabel.frame.origin.y, _scroll.bounds.size.width - 2 * MARGIN - 28.0f, 22.0f)];
    _busyLabel.backgroundColor = [UIColor clearColor];
    _busyLabel.font = [UIFont systemFontOfSize:14.0f];
    _busyLabel.textColor = ACTextColor();
    [_scroll addSubview:_busyLabel];
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, y + 320.0f);
    _scroll.contentOffset = CGPointZero;
    _built = YES;
}

- (void)update
{
    ACTelegram *tg = [ACTelegram shared];
    if (tg.state == ACTGStateReady && tg.authorized) {
        [self.view endEditing:YES];
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    int step = [self currentStep];
    if (!_built || step != _step) { _step = step; [self rebuild]; }
    BOOL busy = tg.busy;
    for (UIButton *b in _buttons) b.enabled = !busy;
    NSString *err = tg.lastError;
    _errLabel.text = [err length] ? err : @" ";
    _errLabel.hidden = busy;
    if (busy) {
        [_spin startAnimating];
        _busyLabel.text = step == 2 ? @"Sprawdzanie hasła…" : (tg.state == ACTGStateConnecting ? @"Łączenie z Telegramem…" : @"Chwileczkę…");
    } else {
        [_spin stopAnimating];
        _busyLabel.text = @"";
    }
}

/* ---------- akcje ---------- */

- (void)sendCodeTapped
{
    [self.view endEditing:YES];
    [self captureValues];
    NSString *idText = [_vApiId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *hash = [_vApiHash stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    ACTelegram *tg = [ACTelegram shared];
    if ([idText intValue] <= 0 || [hash length] < 16) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Brak kluczy" message:@"Wpisz poprawne api_id (liczba) i api_hash (32 znaki) z my.telegram.org." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [a show];
        return;
    }
    [tg saveApiId:[idText intValue] apiHash:hash];
    [tg startLoginWithPhone:_vPhone];
}

- (void)signInTapped
{
    [self.view endEditing:YES];
    [[ACTelegram shared] submitCode:_fCode.text];
}

- (void)passwordTapped
{
    [self.view endEditing:YES];
    [[ACTelegram shared] submitPassword:_fPass.text];
}

- (void)resendTapped { [[ACTelegram shared] resendCode]; }

- (void)backTapped
{
    [self.view endEditing:YES];
    [[ACTelegram shared] cancelLogin];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf
{
    if (tf == _fApiId) [_fApiHash becomeFirstResponder];
    else if (tf == _fApiHash) [_fPhone becomeFirstResponder];
    else if (tf == _fPass) [self passwordTapped];
    else [tf resignFirstResponder];
    return NO;
}

- (void)textFieldDidBeginEditing:(UITextField *)tf
{
    CGRect r = [tf convertRect:tf.bounds toView:_scroll];
    r.origin.y -= 70.0f;
    r.size.height += 140.0f;
    [_scroll scrollRectToVisible:r animated:YES];
}

@end
