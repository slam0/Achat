#import "ACViews.h"
#import "ACTheme.h"
#import "ACMetal.h"

static UIColor *C(int r, int g, int b, CGFloat a)
{
    return [UIColor colorWithRed:r / 255.0f green:g / 255.0f blue:b / 255.0f alpha:a];
}

static void Gradient(CGContextRef c, CGRect r, UIColor *top, UIColor *bottom)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *cols = [NSArray arrayWithObjects:(__bridge id)top.CGColor, (__bridge id)bottom.CGColor, nil];
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, NULL);
    CGContextSaveGState(c);
    CGContextClipToRect(c, r);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, r.origin.y), CGPointMake(0, r.origin.y + r.size.height), 0);
    CGContextRestoreGState(c);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

/* ---------- tło komórki ---------- */

@interface ACGlossBackground : UIView
@property (nonatomic) BOOL selected;
@end

@implementation ACGlossBackground
- (id)initWithFrame:(CGRect)f
{
    if ((self = [super initWithFrame:f])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
- (void)drawRect:(CGRect)rect
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    CGFloat half = (CGFloat)((int)(b.size.height / 2.0f));
    const ACPalette *p = ACP();
    /* w Aero komórki to półprzezroczyste szkło, przez które widać niebo */
    CGFloat a1 = p->aero ? 0.80f : 1.0f, a2 = p->aero ? 0.60f : 1.0f;
    if (_selected) {
        Gradient(c, CGRectMake(0, 0, b.size.width, half), ACRGB(p->selT1, a1 + 0.1f > 1 ? 1 : a1 + 0.1f), ACRGB(p->selT2, a1 + 0.1f > 1 ? 1 : a1 + 0.1f));
        Gradient(c, CGRectMake(0, half, b.size.width, b.size.height - half), ACRGB(p->selB1, 1), ACRGB(p->selB2, 1));
    } else {
        Gradient(c, CGRectMake(0, 0, b.size.width, half), ACRGB(p->cellT1, a1), ACRGB(p->cellT2, a1));
        Gradient(c, CGRectMake(0, half, b.size.width, b.size.height - half), ACRGB(p->cellB1, a2), ACRGB(p->cellB2, a2));
        if (p->aero) {
            /* szklany połysk na górnej połowie */
            Gradient(c, CGRectMake(0, 0, b.size.width, half), C(255, 255, 255, 0.45f), C(255, 255, 255, 0.02f));
        }
    }
    if (p->metal && !_selected) {
        CGContextSaveGState(c);
        CGContextSetAlpha(c, 0.7f);
        [ACBrushedOverlay() drawAsPatternInRect:b];
        CGContextRestoreGState(c);
    }
    [C(255, 255, 255, p->cellHiAlpha) setFill];
    CGContextFillRect(c, CGRectMake(0, 0, b.size.width, 1));
    [(p->aero ? C(70, 140, 190, 0.45f) : C(0, 0, 0, p->cellLoAlpha)) setFill];
    CGContextFillRect(c, CGRectMake(0, b.size.height - 1, b.size.width, 1));
}
@end

@implementation ACCell

+ (ACCell *)cellForTable:(UITableView *)table identifier:(NSString *)ident
{
    ACCell *cell = [table dequeueReusableCellWithIdentifier:ident];
    if (!cell) cell = [[ACCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ident];
    return cell;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuse])) {
        self.backgroundView = [[ACGlossBackground alloc] initWithFrame:self.bounds];
        ACGlossBackground *sel = [[ACGlossBackground alloc] initWithFrame:self.bounds];
        sel.selected = YES;
        self.selectedBackgroundView = sel;
        self.textLabel.textColor = ACTextColor();
        self.textLabel.highlightedTextColor = [UIColor whiteColor];
        ACStyleShadow(self.textLabel);
        self.textLabel.font = [UIFont boldSystemFontOfSize:17.0f];
        self.textLabel.backgroundColor = [UIColor clearColor];
        self.detailTextLabel.textColor = ACSubtleColor();
        self.detailTextLabel.highlightedTextColor = [UIColor colorWithWhite:1.0f alpha:0.9f];
        self.detailTextLabel.font = [UIFont systemFontOfSize:13.0f];
        self.detailTextLabel.backgroundColor = [UIColor clearColor];
    }
    return self;
}
@end

/* ---------- komórka czatu ---------- */

@implementation ACChatCell {
    UIImageView *_avatar;
    UILabel *_time;
    UILabel *_badge;
    UIImageView *_badgeBg;
}

+ (ACChatCell *)chatCellForTable:(UITableView *)table
{
    ACChatCell *cell = [table dequeueReusableCellWithIdentifier:@"chat"];
    if (!cell) cell = [[ACChatCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"chat"];
    return cell;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuse])) {
        _avatar = [[UIImageView alloc] initWithFrame:CGRectMake(10, 9, 48, 48)];
        [self.contentView addSubview:_avatar];
        _time = [[UILabel alloc] initWithFrame:CGRectZero];
        _time.backgroundColor = [UIColor clearColor];
        _time.font = [UIFont systemFontOfSize:12.0f];
        _time.textAlignment = NSTextAlignmentRight;
        _time.textColor = ACAccentColor();
        _time.highlightedTextColor = [UIColor whiteColor];
        [self.contentView addSubview:_time];
        _badgeBg = [[UIImageView alloc] initWithImage:ACBadgeImage()];
        [self.contentView addSubview:_badgeBg];
        _badge = [[UILabel alloc] initWithFrame:CGRectZero];
        _badge.backgroundColor = [UIColor clearColor];
        _badge.textColor = [UIColor whiteColor];
        _badge.font = [UIFont boldSystemFontOfSize:13.0f];
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.shadowColor = [UIColor colorWithWhite:0 alpha:0.5f];
        _badge.shadowOffset = CGSizeMake(0, -1);
        [_badgeBg addSubview:_badge];
        self.detailTextLabel.numberOfLines = 1;
    }
    return self;
}

- (void)configureWithName:(NSString *)name preview:(NSString *)preview time:(NSString *)time unread:(NSInteger)unread
{
    _avatar.image = ACAvatarImage(name, 48.0f);
    self.textLabel.text = name;
    self.detailTextLabel.text = preview;
    _time.text = time;
    if (unread > 0) {
        _badge.text = unread > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)unread];
        _badgeBg.hidden = NO;
    } else {
        _badgeBg.hidden = YES;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    _avatar.frame = CGRectMake(10, 9, 48, 48);
    _time.frame = CGRectMake(w - 70, 11, 62, 16);
    self.textLabel.frame = CGRectMake(68, 10, w - 68 - 76, 22);
    self.detailTextLabel.frame = CGRectMake(68, 34, w - 68 - 44, 18);
    CGFloat bw = 24.0f;
    if (_badge.text.length > 1) bw = 14.0f + 8.0f * _badge.text.length;
    _badgeBg.frame = CGRectMake(w - bw - 10, 34, bw, 24);
    _badge.frame = CGRectMake(0, 1, bw, 20);
}
@end

/* ---------- dymek wiadomości ---------- */

#define BUBBLE_MAXW 232.0f
#define BUBBLE_FONT [UIFont systemFontOfSize:16.0f]

@implementation ACBubbleCell {
    UIImageView *_bubble;
    UILabel *_text;
    UILabel *_time;
    BOOL _out;
}

+ (ACBubbleCell *)bubbleCellForTable:(UITableView *)table
{
    ACBubbleCell *cell = [table dequeueReusableCellWithIdentifier:@"bubble"];
    if (!cell) cell = [[ACBubbleCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"bubble"];
    return cell;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuse])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _bubble = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_bubble];
        _text = [[UILabel alloc] initWithFrame:CGRectZero];
        _text.backgroundColor = [UIColor clearColor];
        _text.numberOfLines = 0;
        _text.font = BUBBLE_FONT;
        [self.contentView addSubview:_text];
        _time = [[UILabel alloc] initWithFrame:CGRectZero];
        _time.backgroundColor = [UIColor clearColor];
        _time.font = [UIFont systemFontOfSize:11.0f];
        [self.contentView addSubview:_time];
    }
    return self;
}

+ (CGSize)textSize:(NSString *)text
{
    CGSize s = [text sizeWithFont:BUBBLE_FONT constrainedToSize:CGSizeMake(BUBBLE_MAXW, 4000) lineBreakMode:NSLineBreakByWordWrapping];
    return CGSizeMake((CGFloat)((int)(s.width + 0.99f)), (CGFloat)((int)(s.height + 0.99f)));
}

+ (CGFloat)heightForText:(NSString *)text width:(CGFloat)tableWidth
{
    return [self textSize:text].height + 32.0f + 14.0f;
}

- (void)configureWithText:(NSString *)text time:(NSString *)time outgoing:(BOOL)outgoing
{
    _out = outgoing;
    _bubble.image = ACBubbleImage(outgoing);
    _text.text = text;
    _text.textColor = ACBubbleTextColor(outgoing);
    const ACPalette *p = ACP();
    BOOL shadowDark = outgoing || !p->light;
    _text.shadowColor = shadowDark ? [UIColor colorWithWhite:0 alpha:0.35f] : [UIColor colorWithWhite:1 alpha:0.8f];
    _text.shadowOffset = CGSizeMake(0, shadowDark ? -1 : 1);
    _time.text = time;
    _time.textColor = p->aero ? C(40, 90, 140, 0.9f) : ACSubtleColor();
    _time.shadowColor = p->light ? [UIColor colorWithWhite:1 alpha:0.7f] : [UIColor colorWithWhite:0 alpha:0.6f];
    _time.shadowOffset = CGSizeMake(0, p->light ? 1 : -1);
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGSize ts = [ACBubbleCell textSize:_text.text ? _text.text : @""];
    CGFloat bw = ts.width + 28.0f;
    if (bw < 54.0f) bw = 54.0f;
    CGFloat bh = ts.height + 22.0f;
    CGFloat x = _out ? w - bw - 10.0f : 10.0f;
    _bubble.frame = CGRectMake(x, 6, bw, bh);
    _text.frame = CGRectMake(x + 14.0f, 6 + 10.0f, ts.width, ts.height);
    CGFloat tw = 120.0f;
    _time.textAlignment = _out ? NSTextAlignmentRight : NSTextAlignmentLeft;
    _time.frame = CGRectMake(_out ? x + bw - tw - 4.0f : x + 4.0f, 6 + bh + 1, tw, 13);
}
@end

/* ---------- nagłówek sekcji ---------- */

@interface ACSectionHeader : UIView
- (id)initWithTitle:(NSString *)title;
@end

@implementation ACSectionHeader {
    NSString *_title;
}
- (id)initWithTitle:(NSString *)title
{
    if ((self = [super initWithFrame:CGRectMake(0, 0, 320, 26)])) {
        _title = [title copy];
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
- (void)drawRect:(CGRect)rect
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    const ACPalette *p = ACP();
    Gradient(c, b, ACRGB(p->hdrT, p->aero ? 0.92f : 1), ACRGB(p->hdrB, p->aero ? 0.92f : 1));
    if (p->aero) Gradient(c, CGRectMake(0, 0, b.size.width, b.size.height / 2), C(255, 255, 255, 0.40f), C(255, 255, 255, 0.04f));
    [C(255, 255, 255, p->light ? 0.55f : 0.14f) setFill];
    CGContextFillRect(c, CGRectMake(0, 0, b.size.width, 1));
    [C(0, 0, 0, 0.35f) setFill];
    CGContextFillRect(c, CGRectMake(0, b.size.height - 1, b.size.width, 1));
    UIFont *font = [UIFont boldSystemFontOfSize:14.0f];
    CGContextSetShadowWithColor(c, CGSizeMake(0, p->metal ? 1 : -1), 0, p->metal ? C(255, 255, 255, 0.4f).CGColor : C(0, 0, 0, 0.6f).CGColor);
    [ACRGB(p->hdrTitle, 1) set];
    [_title drawInRect:CGRectMake(12, 4, b.size.width - 24, 20) withFont:font lineBreakMode:NSLineBreakByTruncatingTail];
}
@end

UIView *ACHeaderForTitle(NSString *title)
{
    return [[ACSectionHeader alloc] initWithTitle:title];
}
