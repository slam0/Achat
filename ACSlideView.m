#import "ACSlideView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

#define TRACK_X 20.0f
#define TRACK_Y 21.0f
#define TRACK_H 52.0f
#define KNOB_W 58.0f
#define KNOB_H 44.0f
#define KNOB_PAD 4.0f

static UIColor *Col(int r, int g, int b, CGFloat a)
{
    return [UIColor colorWithRed:r / 255.0f green:g / 255.0f blue:b / 255.0f alpha:a];
}

static void Grad(CGContextRef c, CGRect r, UIColor *top, UIColor *bottom)
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

/* pas na dole ekranu */
static UIImage *PanelImage(CGFloat w, CGFloat h)
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), YES, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    Grad(c, CGRectMake(0, 0, w, h), Col(70, 72, 75, 1), Col(36, 37, 39, 1));
    [Col(0, 0, 0, 0.85f) setFill];
    CGContextFillRect(c, CGRectMake(0, 0, w, 1));
    [Col(150, 152, 156, 0.45f) setFill];
    CGContextFillRect(c, CGRectMake(0, 1, w, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/* czarny, wpuszczony tor */
static UIImage *TrackImage(CGFloat w, CGFloat h)
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0.5f, 0.5f, w - 1.0f, h - 1.0f);
    UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12.0f];
    /* jasna krawędź pod spodem */
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, 1.0f);
    [Col(120, 122, 126, 0.55f) setFill];
    [outer fill];
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    [outer addClip];
    Grad(c, CGRectMake(0, 0, w, h), Col(8, 8, 9, 1), Col(40, 41, 43, 1));
    /* cień wewnętrzny u góry */
    Grad(c, CGRectMake(0, 0, w, 10), Col(0, 0, 0, 0.7f), Col(0, 0, 0, 0.0f));
    CGContextRestoreGState(c);
    [Col(0, 0, 0, 0.9f) setStroke];
    outer.lineWidth = 1.0f;
    [outer stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/* srebrny uchwyt ze strzałką */
static UIImage *KnobImage(void)
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(KNOB_W, KNOB_H), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0.5f, 0.5f, KNOB_W - 1.0f, KNOB_H - 1.0f);
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:8.0f];
    CGContextSaveGState(c);
    [p addClip];
    CGFloat half = (CGFloat)((int)(KNOB_H / 2.0f));
    Grad(c, CGRectMake(0, 0, KNOB_W, half), Col(252, 252, 252, 1), Col(222, 223, 225, 1));
    Grad(c, CGRectMake(0, half, KNOB_W, KNOB_H - half), Col(196, 198, 202, 1), Col(226, 227, 229, 1));
    CGContextRestoreGState(c);
    [Col(70, 72, 76, 1) setStroke];
    p.lineWidth = 1.0f;
    [p stroke];
    [Col(255, 255, 255, 0.9f) setFill];
    CGContextFillRect(c, CGRectMake(3, 1, KNOB_W - 6, 1));
    /* strzałka */
    CGFloat cx = KNOB_W / 2.0f, cy = KNOB_H / 2.0f;
    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:CGPointMake(cx - 15, cy - 5)];
    [arrow addLineToPoint:CGPointMake(cx + 1, cy - 5)];
    [arrow addLineToPoint:CGPointMake(cx + 1, cy - 12)];
    [arrow addLineToPoint:CGPointMake(cx + 15, cy)];
    [arrow addLineToPoint:CGPointMake(cx + 1, cy + 12)];
    [arrow addLineToPoint:CGPointMake(cx + 1, cy + 5)];
    [arrow addLineToPoint:CGPointMake(cx - 15, cy + 5)];
    [arrow closePath];
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, 1.0f);
    [Col(255, 255, 255, 0.95f) setFill];
    [arrow fill];
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    [arrow addClip];
    Grad(c, CGRectMake(0, cy - 12, KNOB_W, 24), Col(128, 131, 137, 1), Col(88, 91, 97, 1));
    CGContextRestoreGState(c);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@implementation ACSlideView {
    UIImageView *_panel, *_track, *_knob;
    UILabel *_label, *_shine;
    CAGradientLayer *_mask;
    BOOL _drag, _done;
    CGFloat _grab;
}

@synthesize title = _title;

- (id)initWithFrame:(CGRect)f
{
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor blackColor];
        _panel = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self addSubview:_panel];
        _track = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self addSubview:_track];
        UIFont *font = [UIFont fontWithName:@"HelveticaNeue" size:22.0f];
        if (!font) font = [UIFont systemFontOfSize:22.0f];
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.backgroundColor = [UIColor clearColor];
        _label.font = font;
        _label.textColor = Col(120, 122, 126, 1);
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumFontSize = 14.0f;
        [self addSubview:_label];
        _shine = [[UILabel alloc] initWithFrame:CGRectZero];
        _shine.backgroundColor = [UIColor clearColor];
        _shine.font = font;
        _shine.textColor = [UIColor whiteColor];
        _shine.textAlignment = NSTextAlignmentCenter;
        _shine.adjustsFontSizeToFitWidth = YES;
        _shine.minimumFontSize = 14.0f;
        [self addSubview:_shine];
        _mask = [CAGradientLayer layer];
        _mask.colors = [NSArray arrayWithObjects:(__bridge id)[UIColor clearColor].CGColor, (__bridge id)[UIColor whiteColor].CGColor, (__bridge id)[UIColor clearColor].CGColor, nil];
        _mask.startPoint = CGPointMake(0, 0.5f);
        _mask.endPoint = CGPointMake(1, 0.5f);
        _mask.locations = [NSArray arrayWithObjects:[NSNumber numberWithFloat:-0.4f], [NSNumber numberWithFloat:-0.2f], [NSNumber numberWithFloat:0.0f], nil];
        _shine.layer.mask = _mask;
        _knob = [[UIImageView alloc] initWithImage:KnobImage()];
        [self addSubview:_knob];
    }
    return self;
}

- (void)setTitle:(NSString *)t
{
    _title = [t copy];
    _label.text = t;
    _shine.text = t;
}

- (CGFloat)minX { return TRACK_X + KNOB_PAD; }
- (CGFloat)maxX { return self.bounds.size.width - TRACK_X - KNOB_PAD - KNOB_W; }

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _panel.frame = self.bounds;
    _panel.image = PanelImage(w, h);
    CGFloat ty = (CGFloat)((int)((h - TRACK_H) / 2.0f)) + 0.0f;
    if (ty < TRACK_Y - 4) ty = TRACK_Y;
    _track.frame = CGRectMake(TRACK_X, ty, w - 2 * TRACK_X, TRACK_H);
    _track.image = TrackImage(w - 2 * TRACK_X, TRACK_H);
    if (!_drag && !_done) _knob.frame = CGRectMake([self minX], ty + (TRACK_H - KNOB_H) / 2.0f, KNOB_W, KNOB_H);
    CGRect lf = CGRectMake(TRACK_X + KNOB_PAD + KNOB_W + 6, ty, w - 2 * TRACK_X - KNOB_W - 2 * KNOB_PAD - 12, TRACK_H);
    _label.frame = lf;
    _shine.frame = lf;
    _mask.frame = _shine.bounds;
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    if (self.window) [self startShine];
}

- (void)startShine
{
    [_mask removeAllAnimations];
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"locations"];
    a.fromValue = [NSArray arrayWithObjects:[NSNumber numberWithFloat:-0.4f], [NSNumber numberWithFloat:-0.2f], [NSNumber numberWithFloat:0.0f], nil];
    a.toValue = [NSArray arrayWithObjects:[NSNumber numberWithFloat:1.0f], [NSNumber numberWithFloat:1.2f], [NSNumber numberWithFloat:1.4f], nil];
    a.duration = 2.4;
    a.repeatCount = HUGE_VALF;
    [_mask addAnimation:a forKey:@"shine"];
}

- (void)setProgressUI
{
    CGFloat span = [self maxX] - [self minX];
    CGFloat p = span > 1 ? (_knob.frame.origin.x - [self minX]) / span : 0;
    CGFloat a = 1.0f - 1.8f * p;
    if (a < 0) a = 0;
    _label.alpha = a;
    _shine.alpha = a;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (_done) return;
    CGPoint pt = [[touches anyObject] locationInView:self];
    if (CGRectContainsPoint(CGRectInset(_knob.frame, -10, -10), pt)) {
        _drag = YES;
        _grab = pt.x - _knob.frame.origin.x;
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (!_drag) return;
    CGPoint pt = [[touches anyObject] locationInView:self];
    CGFloat x = pt.x - _grab;
    if (x < [self minX]) x = [self minX];
    if (x > [self maxX]) x = [self maxX];
    CGRect k = _knob.frame;
    k.origin.x = x;
    _knob.frame = k;
    [self setProgressUI];
}

- (void)finishTouch
{
    if (!_drag) return;
    _drag = NO;
    CGFloat span = [self maxX] - [self minX];
    CGFloat p = span > 1 ? (_knob.frame.origin.x - [self minX]) / span : 0;
    if (p >= 0.9f) {
        _done = YES;
        CGRect k = _knob.frame;
        k.origin.x = [self maxX];
        _knob.frame = k;
        [self setProgressUI];
        [self sendActionsForControlEvents:UIControlEventValueChanged];
        [self performSelector:@selector(reset) withObject:nil afterDelay:0.8];
    } else {
        [self snapBack];
    }
}

- (void)snapBack
{
    [UIView animateWithDuration:0.25 animations:^{
        CGRect k = _knob.frame;
        k.origin.x = [self minX];
        _knob.frame = k;
        _label.alpha = 1.0f;
        _shine.alpha = 1.0f;
    }];
}

- (void)reset
{
    _done = NO;
    _drag = NO;
    [self snapBack];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self finishTouch]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self finishTouch]; }

@end
