#import "ACMetal.h"
#import "ACTheme.h"

static UIColor *C(int r, int g, int b, CGFloat a)
{
    return [UIColor colorWithRed:r / 255.0f green:g / 255.0f blue:b / 255.0f alpha:a];
}

/* ---------- smugi szczotkowania ---------- */

UIImage *ACBrushedOverlay(void)
{
    static UIImage *img;
    if (img) return img;
    const int W = 192, H = 96;
    unsigned int seed = 20241025u;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(W, H), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    for (int row = 0; row < H * 2; row++) {                 /* wiersze co pół punktu = piksel na ekranie retina */
        CGFloat y = row * 0.5f;
        for (int k = 0; k < 3; k++) {
            seed = seed * 1664525u + 1013904223u;
            int x0 = (int)((seed >> 8) % W);
            seed = seed * 1664525u + 1013904223u;
            int len = 24 + (int)((seed >> 8) % 120);
            seed = seed * 1664525u + 1013904223u;
            int shade = (int)((seed >> 12) & 1);
            int a = 3 + (int)((seed >> 16) % 9);             /* 3..11 setnych krycia */
            CGFloat alpha = a / 100.0f * (shade ? 1.0f : 0.8f);
            if (shade) [C(255, 255, 255, alpha) setFill]; else [C(0, 0, 0, alpha) setFill];
            CGContextFillRect(c, CGRectMake(x0, y, len, 0.5f));
            if (x0 + len > W) CGContextFillRect(c, CGRectMake(x0 - W, y, len, 0.5f));   /* zawinięcie: kafelki łączą się bez szwu */
        }
    }
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

void ACMetalFill(CGContextRef c, CGRect r, NSArray *colors, const CGFloat *locations, CGFloat texture)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locations);
    CGContextSaveGState(c);
    CGContextClipToRect(c, r);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, r.origin.y), CGPointMake(0, r.origin.y + r.size.height), 0);
    if (texture > 0.0f) {
        CGContextSetAlpha(c, texture);
        [ACBrushedOverlay() drawAsPatternInRect:r];
    }
    CGContextRestoreGState(c);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

/* ---------- śrubka ---------- */

UIImage *ACScrewImage(CGFloat d, int variant)
{
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    variant &= 3;
    NSString *key = [NSString stringWithFormat:@"%d-%d", (int)(d * 2.0f), variant];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;

    static const CGFloat angles[4] = { 0.35f, 1.2f, 2.1f, 2.9f };
    CGFloat pad = 2.0f, s = d + 2 * pad, r = d / 2;
    CGPoint ctr = CGPointMake(s / 2, s / 2);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();

    /* jasna krawędź od dołu i ciemny rowek wokół */
    [C(255, 255, 255, 0.65f) setFill];
    CGContextFillEllipseInRect(c, CGRectMake(ctr.x - r - 0.6f, ctr.y - r + 0.1f, 2 * r + 1.2f, 2 * r + 1.2f));
    [C(60, 66, 76, 0.92f) setFill];
    CGContextFillEllipseInRect(c, CGRectMake(ctr.x - r - 0.6f, ctr.y - r - 0.6f, 2 * r + 1.2f, 2 * r + 1.2f));

    /* kopuła: światło z lewej góry */
    CGContextSaveGState(c);
    CGContextAddEllipseInRect(c, CGRectMake(ctr.x - r, ctr.y - r, 2 * r, 2 * r));
    CGContextClip(c);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *cols = [NSArray arrayWithObjects:(__bridge id)C(252, 253, 254, 1).CGColor, (__bridge id)C(120, 127, 138, 1).CGColor, nil];
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, NULL);
    CGPoint light = CGPointMake(ctr.x - 0.35f * r, ctr.y - 0.4f * r);
    CGContextDrawRadialGradient(c, g, light, 0, light, 1.3f * r, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    CGContextRestoreGState(c);

    /* krzyżak */
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, ctr.x, ctr.y);
    CGContextRotateCTM(c, angles[variant]);
    CGFloat L = 0.72f * r, w = 0.45f;
    [C(255, 255, 255, 0.5f) setFill];
    CGContextFillRect(c, CGRectMake(-L, -w + 0.6f, 2 * L, 2 * w));
    CGContextFillRect(c, CGRectMake(-w, -L + 0.6f, 2 * w, 2 * L));
    [C(58, 64, 76, 1) setFill];
    CGContextFillRect(c, CGRectMake(-L, -w, 2 * L, 2 * w));
    CGContextFillRect(c, CGRectMake(-w, -L, 2 * w, 2 * L));
    CGContextRestoreGState(c);

    [C(70, 76, 88, 1) setStroke];
    CGContextSetLineWidth(c, 0.6f);
    CGContextStrokeEllipseInRect(c, CGRectMake(ctr.x - r, ctr.y - r, 2 * r, 2 * r));

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [cache setObject:img forKey:key];
    return img;
}

/* ---------- chrom ---------- */

static UIColor *Tinted(int r, int g, int b)
{
    const ACPalette *p = ACP();
    if (p->tintAmt > 0.0f) {
        r = (int)(r + (p->tint[0] - r) * p->tintAmt + 0.5f);
        g = (int)(g + (p->tint[1] - g) * p->tintAmt + 0.5f);
        b = (int)(b + (p->tint[2] - b) * p->tintAmt + 0.5f);
    }
    return C(r, g, b, 1);
}

UIImage *ACChromeImage(void)
{
    static UIImage *imgs[16];
    static NSInteger which[16];
    NSInteger th = ACCurrentTheme();
    UIImage *img = (th >= 0 && th < 16) ? imgs[th] : nil;
    if (img && which[th] == th + 1) return img;
    CGFloat w = 24.0f, h = 44.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0.5f, 0.5f, w - 1.0f, h - 1.5f);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:9.0f];
    CGContextSaveGState(c);
    [shape addClip];
    NSArray *cols = [NSArray arrayWithObjects:Tinted(255, 255, 255), Tinted(244, 246, 248), Tinted(206, 211, 218), Tinted(158, 165, 175), Tinted(188, 194, 202), Tinted(226, 230, 235), nil];
    NSMutableArray *cg = [NSMutableArray array];
    for (UIColor *u in cols) [cg addObject:(__bridge id)u.CGColor];
    static const CGFloat locs[6] = { 0.0f, 0.12f, 0.48f, 0.5f, 0.78f, 1.0f };
    ACMetalFill(c, CGRectMake(0, 0, w, h), cg, locs, 0.0f);
    CGContextRestoreGState(c);
    [C(84, 90, 101, 1) setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, 1.0f, 1.0f) cornerRadius:8.0f];
    [C(255, 255, 255, 0.75f) setStroke];
    inner.lineWidth = 0.8f;
    [inner stroke];
    [C(255, 255, 255, 0.55f) setFill];
    CGContextFillRect(c, CGRectMake(6, h - 1, w - 12, 1));
    UIImage *raw = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    img = [raw resizableImageWithCapInsets:UIEdgeInsetsMake(14, 10, 14, 10)];
    if (th >= 0 && th < 16) { imgs[th] = img; which[th] = th + 1; }
    return img;
}

/* ---------- płyta ---------- */

@implementation ACPlateView

- (id)initWithFrame:(CGRect)f
{
    if ((self = [super initWithFrame:f])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.42f;
        self.layer.shadowRadius = 4.0f;
        self.layer.shadowOffset = CGSizeMake(0, 2);
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:14.0f].CGPath;
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    const ACPalette *p = ACP();
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 0.5f, 0.5f) cornerRadius:14.0f];
    CGContextSaveGState(c);
    [path addClip];
    NSArray *cols = [NSArray arrayWithObjects:(__bridge id)ACRGB(p->plateT, 1).CGColor, (__bridge id)ACRGB(p->plateM, 1).CGColor, (__bridge id)ACRGB(p->plateB, 1).CGColor, nil];
    static const CGFloat locs[3] = { 0.0f, 0.5f, 1.0f };
    ACMetalFill(c, b, cols, locs, p->texAmp);
    CGContextRestoreGState(c);
    [C(70, 76, 88, p->metal || p->light ? 1.0f : 0.9f) setStroke];
    path.lineWidth = 1.0f;
    [path stroke];
    UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 1.5f, 1.5f) cornerRadius:13.0f];
    [C(255, 255, 255, p->light ? 0.9f : 0.22f) setStroke];
    inner.lineWidth = 1.0f;
    [inner stroke];

    if (self.grooveY > 0.0f) {
        [C(0, 0, 0, p->light ? 0.38f : 0.7f) setFill];
        CGContextFillRect(c, CGRectMake(18, self.grooveY, b.size.width - 36, 1));
        [C(255, 255, 255, p->light ? 0.95f : 0.18f) setFill];
        CGContextFillRect(c, CGRectMake(18, self.grooveY + 1, b.size.width - 36, 1));
    }

    CGFloat d = 9.0f, off = 11.0f, s = d + 4.0f;
    CGPoint pts[4] = { CGPointMake(off, off), CGPointMake(b.size.width - off, off),
                       CGPointMake(off, b.size.height - off), CGPointMake(b.size.width - off, b.size.height - off) };
    for (int i = 0; i < 4; i++) {
        [ACScrewImage(d, i) drawAtPoint:CGPointMake(pts[i].x - s / 2, pts[i].y - s / 2)];
    }
}

@end
