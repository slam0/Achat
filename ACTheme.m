#import "ACTheme.h"
#import "ACStore.h"
#import "ACMetal.h"

NSString *const ACAppearanceDidChangeNotification = @"ACAppearanceDidChangeNotification";

/* ---------- paleta i motywy ---------- */

#define NTHEMES 10

/* aero: 0 zwykły, 1 szkło Aero z niebem. metal: 0 zwykły, 1 szczotkowany metal (z przebarwieniem tint). */
typedef struct {
    NSString *name;
    NSString *kind;
    int accent[3];
    int light, metal, aero;
    int tint[3];
    int tintPct;
    int sky[15];            /* skyT, skyM, skyB, hillT, hillB (Aero) */
} ACThemeDef;

static const ACThemeDef kThemes[NTHEMES] = {
    { @"Frutiger Aero",  @"Szkło Aero", {   0, 150, 235 }, 1, 0, 1, {0,0,0}, 0,
      { 38, 146, 228,   132, 210, 250,   224, 246, 255,   124, 206, 72,   44, 148, 40 } },
    { @"Aluminium",      @"Metal",      {  22, 118, 220 }, 1, 1, 0, {0,0,0}, 0, {0} },
    { @"Aero Zieleń",    @"Szkło Aero", {  54, 176,  58 }, 1, 0, 1, {0,0,0}, 0,
      { 16, 168, 190,   112, 226, 208,   218, 252, 238,   158, 222, 64,   58, 158, 38 } },
    { @"Mosiądz",        @"Metal",      { 176, 108,  18 }, 1, 1, 0, { 214, 172, 84 }, 44, {0} },
    { @"Różowe złoto",   @"Metal",      { 206,  80, 102 }, 1, 1, 0, { 230, 152, 142 }, 42, {0} },
    { @"Grafit",         @"Grafit",     { 255, 138,   0 }, 0, 0, 0, {0,0,0}, 0, {0} },
    { @"Błękit",         @"Grafit",     {  40, 150, 255 }, 0, 0, 0, {0,0,0}, 0, {0} },
    { @"Czerwień",       @"Grafit",     { 240,  70,  70 }, 0, 0, 0, {0,0,0}, 0, {0} },
    { @"Zieleń",         @"Grafit",     {  90, 200,  70 }, 0, 0, 0, {0,0,0}, 0, {0} },
    { @"Fiolet",         @"Grafit",     { 170, 110, 255 }, 0, 0, 0, {0,0,0}, 0, {0} },
};

static ACPalette gPal;
static NSInteger gTheme = -1;

#define SET(dst, r, g, b) do { (dst)[0] = (r); (dst)[1] = (g); (dst)[2] = (b); } while (0)

static void Copy3(int *dst, const int *src) { dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; }

static void Mix(int *dst, const int *a, const int *b, float t)
{
    for (int i = 0; i < 3; i++) dst[i] = (int)(a[i] + (b[i] - a[i]) * t + 0.5f);
}

static void BuildPalette(NSInteger theme, ACPalette *p)
{
    { unsigned char *raw = (unsigned char *)p; for (size_t i = 0; i < sizeof(*p); i++) raw[i] = 0; }
    const int white[3] = { 255, 255, 255 }, black[3] = { 0, 0, 0 };
    p->light = kThemes[theme].light;
    p->metal = kThemes[theme].metal;
    p->aero = kThemes[theme].aero;
    for (int i = 0; i < 3; i++) p->accent[i] = kThemes[theme].accent[i];
    if (!p->light) {
        SET(p->bg, 34, 36, 40);    SET(p->bgHi, 40, 42, 47);  SET(p->bgLo, 30, 32, 36);
        SET(p->barT1, 112, 116, 126); SET(p->barT2, 66, 69, 77); SET(p->barB1, 40, 42, 48); SET(p->barB2, 22, 23, 27);
        SET(p->barTint, 58, 61, 69);
        SET(p->cellT1, 66, 69, 77); SET(p->cellT2, 52, 55, 62); SET(p->cellB1, 44, 46, 52); SET(p->cellB2, 38, 40, 45);
        SET(p->text, 238, 240, 244); SET(p->subtle, 150, 156, 168); SET(p->tabOff, 150, 156, 168);
        SET(p->hdrT, 30, 32, 36);  SET(p->hdrB, 14, 15, 18);  SET(p->hdrRight, 150, 156, 168);
        SET(p->fieldT, 12, 13, 16); SET(p->fieldB, 30, 32, 37); SET(p->fieldText, 255, 255, 255);
        SET(p->panelT, 18, 19, 23); SET(p->panelB, 30, 32, 37);
        SET(p->sep, 18, 19, 22);
        SET(p->neutT, 104, 108, 118); SET(p->neutB, 44, 46, 52); SET(p->neutBorder, 10, 11, 14);
        SET(p->shadow, 0, 0, 0); SET(p->chrome, 26, 28, 33); SET(p->danger, 255, 115, 115);
        p->shadowAlpha = 0.8f; p->shadowDY = -1.0f; p->cellHiAlpha = 0.14f; p->cellLoAlpha = 0.55f;
        /* delikatne przebarwienie grafitu kolorem motywu (poza pierwszym, czystym grafitem) */
        if (theme != 5) {
            int *group[] = { p->bg, p->bgHi, p->bgLo, p->barT1, p->barT2, p->barB1, p->barB2, p->barTint, p->cellT1, p->cellT2,
                             p->cellB1, p->cellB2, p->hdrT, p->hdrB, p->fieldT, p->fieldB, p->panelT, p->panelB,
                             p->sep, p->neutT, p->neutB, p->neutBorder, p->chrome };
            for (size_t i = 0; i < sizeof(group) / sizeof(group[0]); i++) Mix(group[i], group[i], p->accent, 0.11f);
        }
        Copy3(p->hdrTitle, p->accent);
        Copy3(p->tabOn, p->accent);
        Mix(p->selT1, p->accent, black, 0.40f); Mix(p->selT2, p->accent, black, 0.56f);
        Mix(p->selB1, p->accent, black, 0.64f); Mix(p->selB2, p->accent, black, 0.72f);
    } else {
        SET(p->bg, 222, 225, 231); SET(p->bgHi, 231, 234, 239); SET(p->bgLo, 212, 215, 221);
        SET(p->barT1, 146, 158, 178); SET(p->barT2, 110, 123, 145); SET(p->barB1, 82, 95, 117); SET(p->barB2, 60, 72, 93);
        SET(p->barTint, 96, 109, 131);
        SET(p->cellT1, 253, 253, 254); SET(p->cellT2, 244, 246, 248); SET(p->cellB1, 236, 238, 242); SET(p->cellB2, 228, 231, 235);
        SET(p->text, 30, 33, 40); SET(p->subtle, 98, 106, 120); SET(p->tabOff, 196, 204, 216); SET(p->tabOn, 255, 255, 255);
        SET(p->hdrT, 150, 159, 174); SET(p->hdrB, 116, 125, 141); SET(p->hdrTitle, 255, 255, 255); SET(p->hdrRight, 238, 242, 248);
        SET(p->fieldT, 226, 229, 235); SET(p->fieldB, 250, 251, 253); SET(p->fieldText, 28, 31, 38);
        SET(p->panelT, 255, 255, 255); SET(p->panelB, 232, 236, 241);
        SET(p->sep, 200, 204, 212);
        SET(p->neutT, 140, 149, 165); SET(p->neutB, 88, 97, 114); SET(p->neutBorder, 62, 70, 86);
        SET(p->shadow, 255, 255, 255); SET(p->chrome, 74, 86, 108); SET(p->danger, 196, 32, 32);
        p->shadowAlpha = 0.9f; p->shadowDY = 1.0f; p->cellHiAlpha = 0.9f; p->cellLoAlpha = 0.16f;
        Mix(p->selT1, p->accent, black, 0.05f); Mix(p->selT2, p->accent, black, 0.15f);
        Mix(p->selB1, p->accent, black, 0.25f); Mix(p->selB2, p->accent, black, 0.30f);
    }
    if (p->metal) {
        SET(p->bg, 198, 202, 208);
        SET(p->barT1, 244, 246, 248); SET(p->barT2, 206, 211, 218); SET(p->barB1, 190, 196, 205); SET(p->barB2, 160, 166, 176);
        SET(p->barTint, 160, 167, 178);
        SET(p->subtle, 92, 99, 112); SET(p->tabOff, 84, 90, 102);
        Copy3(p->tabOn, p->accent);
        SET(p->hdrT, 92, 98, 110); SET(p->hdrB, 56, 61, 70); SET(p->hdrTitle, 236, 240, 245); SET(p->hdrRight, 190, 197, 208);
        SET(p->sep, 168, 173, 182);
        SET(p->plateT, 248, 249, 250); SET(p->plateM, 226, 229, 234); SET(p->plateB, 196, 201, 209);
        SET(p->chromeText, 40, 45, 54);
        p->texAmp = 1.0f;
        int tp = kThemes[theme].tintPct;
        if (tp > 0) {
            /* przebarwienie metalu: mosiądz, różowe złoto */
            Copy3(p->tint, kThemes[theme].tint);
            p->tintAmt = tp / 100.0f;
            int *group[] = { p->bg, p->barT1, p->barT2, p->barB1, p->barB2, p->barTint, p->hdrT, p->hdrB, p->sep,
                             p->plateT, p->plateM, p->plateB, p->cellT1, p->cellT2, p->cellB1, p->cellB2 };
            for (size_t i = 0; i < sizeof(group) / sizeof(group[0]); i++) Mix(group[i], group[i], p->tint, p->tintAmt);
            Mix(p->subtle, p->subtle, p->tint, 0.2f);
        }
    } else if (p->aero) {
        /* szkło Aero: błękitne, półprzezroczyste, z dużym połyskiem */
        const int *s = kThemes[theme].sky;
        Copy3(p->skyT, s); Copy3(p->skyM, s + 3); Copy3(p->skyB, s + 6); Copy3(p->hillT, s + 9); Copy3(p->hillB, s + 12);
        Copy3(p->bg, p->skyM);
        Mix(p->barT1, p->accent, white, 0.52f); Mix(p->barT2, p->accent, white, 0.12f);
        Mix(p->barB1, p->accent, black, 0.20f); Mix(p->barB2, p->accent, black, 0.46f);
        Mix(p->barTint, p->accent, black, 0.22f);
        SET(p->cellT1, 255, 255, 255); SET(p->cellT2, 238, 250, 255); SET(p->cellB1, 224, 244, 255); SET(p->cellB2, 210, 236, 252);
        SET(p->text, 12, 48, 92); SET(p->subtle, 58, 98, 140); SET(p->tabOff, 214, 238, 255); SET(p->tabOn, 255, 255, 255);
        Mix(p->hdrT, p->accent, white, 0.30f); Mix(p->hdrB, p->accent, black, 0.12f);
        SET(p->hdrTitle, 255, 255, 255); SET(p->hdrRight, 228, 246, 255);
        SET(p->fieldT, 214, 232, 246); SET(p->fieldB, 255, 255, 255); SET(p->fieldText, 12, 48, 92);
        SET(p->panelT, 255, 255, 255); SET(p->panelB, 226, 244, 255);
        SET(p->sep, 150, 196, 228);
        Mix(p->neutT, p->accent, white, 0.60f); Mix(p->neutB, p->accent, black, 0.05f); Mix(p->neutBorder, p->accent, black, 0.50f);
        SET(p->plateT, 255, 255, 255); SET(p->plateM, 232, 246, 255); SET(p->plateB, 204, 230, 250);
        SET(p->chromeText, 255, 255, 255);
        Mix(p->chrome, p->accent, black, 0.40f);
        p->cellHiAlpha = 0.9f; p->cellLoAlpha = 0.10f;
        Mix(p->selT1, p->accent, white, 0.32f); Mix(p->selT2, p->accent, white, 0.10f);
        Mix(p->selB1, p->accent, black, 0.08f); Mix(p->selB2, p->accent, black, 0.22f);
    } else if (p->light) {
        SET(p->plateT, 253, 254, 255); SET(p->plateM, 238, 241, 245); SET(p->plateB, 214, 219, 226);
        SET(p->chromeText, 255, 255, 255);
    } else {
        SET(p->plateT, 98, 102, 112); SET(p->plateM, 70, 73, 81); SET(p->plateB, 46, 48, 54);
        SET(p->chromeText, 255, 255, 255);
    }
    Mix(p->accentGelT, p->accent, white, 0.25f);
    Mix(p->accentGelB, p->accent, black, 0.18f);
    Mix(p->accentGelBorder, p->accent, black, 0.62f);
}

NSInteger ACThemeCount(void) { return NTHEMES; }

NSInteger ACCurrentTheme(void)
{
    if (gTheme < 0) {
        NSInteger t = [ACStore shared].themeIndex;
        gTheme = (t >= 0 && t < NTHEMES) ? t : 0;
        BuildPalette(gTheme, &gPal);
    }
    return gTheme;
}

const ACPalette *ACP(void)
{
    ACCurrentTheme();
    return &gPal;
}

static UIImage *gGelCache[NTHEMES][4];
static UIColor *gBgCache[NTHEMES];
static UIImage *gSkyCache[NTHEMES];
static CGSize gSkySize;

void ACSetTheme(NSInteger index)
{
    if (index < 0 || index >= NTHEMES) index = 0;
    [ACStore shared].themeIndex = index;
    gTheme = -1;
    ACCurrentTheme();
    [[NSNotificationCenter defaultCenter] postNotificationName:ACAppearanceDidChangeNotification object:nil];
}

NSString *ACThemeName(NSInteger index)
{
    if (index < 0 || index >= NTHEMES) return @"";
    return kThemes[index].name;
}

NSString *ACThemeKind(NSInteger index)
{
    if (index < 0 || index >= NTHEMES) return @"";
    return kThemes[index].kind;
}

UIColor *ACRGB(const int *c, CGFloat a)
{
    return [UIColor colorWithRed:c[0] / 255.0f green:c[1] / 255.0f blue:c[2] / 255.0f alpha:a];
}

static UIColor *RGBA(int r, int g, int b, CGFloat a)
{
    return [UIColor colorWithRed:r / 255.0f green:g / 255.0f blue:b / 255.0f alpha:a];
}

UIColor *ACTextColor(void)   { return ACRGB(ACP()->text, 1); }
UIColor *ACSubtleColor(void) { return ACRGB(ACP()->subtle, 1); }
UIColor *ACAccentColor(void) { return ACRGB(ACP()->accent, 1); }

void ACStyleShadow(UILabel *l)
{
    const ACPalette *p = ACP();
    l.shadowColor = ACRGB(p->shadow, p->shadowAlpha);
    l.shadowOffset = CGSizeMake(0, p->shadowDY);
}

static void Fill(CGContextRef c, CGRect r, UIColor *top, UIColor *bottom)
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

static void Radial(CGContextRef c, CGPoint center, CGFloat radius, UIColor *inner, UIColor *outer)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *cols = [NSArray arrayWithObjects:(__bridge id)inner.CGColor, (__bridge id)outer.CGColor, nil];
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, NULL);
    CGContextDrawRadialGradient(c, g, center, 0, center, radius, 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

/* ---------- tło ---------- */

/* Niebo Frutiger Aero: gradient, słońce z promieniami, chmurki, wzgórza i błyszczące bąble. */
static UIImage *AeroSkyImage(CGSize size)
{
    const ACPalette *p = ACP();
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGFloat w = size.width, h = size.height;
    {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *cols = [NSArray arrayWithObjects:(__bridge id)ACRGB(p->skyT, 1).CGColor, (__bridge id)ACRGB(p->skyM, 1).CGColor,
                         (__bridge id)ACRGB(p->skyB, 1).CGColor, nil];
        static const CGFloat locs[3] = { 0.0f, 0.55f, 0.86f };
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, locs);
        CGContextDrawLinearGradient(c, g, CGPointMake(0, 0), CGPointMake(0, h), 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
    }
    /* słońce */
    CGPoint sun = CGPointMake(w * 0.82f, h * 0.10f);
    Radial(c, sun, w * 1.1f, RGBA(255, 255, 255, 0.72f), RGBA(255, 255, 255, 0.0f));
    /* promienie */
    CGContextSaveGState(c);
    static const float ray[7][4] = {
        { -0.3233f, 0.9463f, -0.3887f, 0.9214f },
        { -0.4787f, 0.8780f, -0.5390f, 0.8423f },
        { -0.6204f, 0.7843f, -0.6737f, 0.7390f },
        { -0.7441f, 0.6681f, -0.7890f, 0.6144f },
        { -0.8464f, 0.5325f, -0.8816f, 0.4720f },
        { -0.9243f, 0.3817f, -0.9487f, 0.3161f },
        { -0.9755f, 0.2198f, -0.9885f, 0.1510f } };
    for (int i = 0; i < 7; i++) {
        CGContextBeginPath(c);
        CGContextMoveToPoint(c, sun.x, sun.y);
        CGContextAddLineToPoint(c, sun.x + ray[i][0] * h * 1.3f, sun.y + ray[i][1] * h * 1.3f);
        CGContextAddLineToPoint(c, sun.x + ray[i][2] * h * 1.3f, sun.y + ray[i][3] * h * 1.3f);
        CGContextClosePath(c);
        CGContextSetRGBFillColor(c, 1, 1, 1, 0.07f);
        CGContextFillPath(c);
    }
    CGContextRestoreGState(c);
    /* chmurki z puchatych kul */
    static const float clouds[3][3] = { { 0.18f, 0.20f, 1.0f }, { 0.62f, 0.34f, 0.75f }, { 0.30f, 0.50f, 0.6f } };
    for (int i = 0; i < 3; i++) {
        CGFloat cx = w * clouds[i][0], cy = h * clouds[i][1], sc = clouds[i][2] * w * 0.20f;
        static const float off[5][3] = { { -1.1f, 0.2f, 0.8f }, { -0.4f, -0.2f, 1.0f }, { 0.4f, -0.1f, 0.95f }, { 1.1f, 0.2f, 0.75f }, { 0.0f, 0.3f, 1.0f } };
        for (int k = 0; k < 5; k++) {
            Radial(c, CGPointMake(cx + off[k][0] * sc, cy + off[k][1] * sc * 0.6f), sc * off[k][2],
                   RGBA(255, 255, 255, 0.55f), RGBA(255, 255, 255, 0.0f));
        }
    }
    /* wzgórza */
    CGFloat base = h * 0.80f;
    UIBezierPath *back = [UIBezierPath bezierPath];
    [back moveToPoint:CGPointMake(0, base - 14)];
    [back addCurveToPoint:CGPointMake(w, base - 30) controlPoint1:CGPointMake(w * 0.35f, base - 64) controlPoint2:CGPointMake(w * 0.70f, base + 6)];
    [back addLineToPoint:CGPointMake(w, h)];
    [back addLineToPoint:CGPointMake(0, h)];
    [back closePath];
    CGContextSaveGState(c);
    [back addClip];
    Fill(c, CGRectMake(0, base - 70, w, h - base + 70), RGBA(p->hillT[0], p->hillT[1], p->hillT[2], 0.70f), RGBA(p->hillB[0], p->hillB[1], p->hillB[2], 0.70f));
    CGContextRestoreGState(c);
    UIBezierPath *front = [UIBezierPath bezierPath];
    [front moveToPoint:CGPointMake(0, base + 20)];
    [front addCurveToPoint:CGPointMake(w, base + 8) controlPoint1:CGPointMake(w * 0.40f, base - 20) controlPoint2:CGPointMake(w * 0.75f, base + 52)];
    [front addLineToPoint:CGPointMake(w, h)];
    [front addLineToPoint:CGPointMake(0, h)];
    [front closePath];
    CGContextSaveGState(c);
    [front addClip];
    Fill(c, CGRectMake(0, base - 30, w, h - base + 30), ACRGB(p->hillT, 1), ACRGB(p->hillB, 1));
    Fill(c, CGRectMake(0, base - 30, w, 46), RGBA(255, 255, 255, 0.30f), RGBA(255, 255, 255, 0.0f));
    CGContextRestoreGState(c);
    /* błyszczące bąble */
    static const float bub[16][3] = {
        { 0.10f, 0.62f, 22 }, { 0.26f, 0.74f, 12 }, { 0.40f, 0.58f, 34 }, { 0.58f, 0.70f, 16 },
        { 0.72f, 0.55f, 26 }, { 0.88f, 0.68f, 40 }, { 0.16f, 0.88f, 30 }, { 0.50f, 0.90f, 18 },
        { 0.80f, 0.90f, 24 }, { 0.92f, 0.42f, 14 }, { 0.05f, 0.40f, 18 }, { 0.34f, 0.34f, 10 },
        { 0.66f, 0.28f, 14 }, { 0.50f, 0.46f, 8 }, { 0.22f, 0.14f, 12 }, { 0.94f, 0.80f, 10 } };
    for (int i = 0; i < 16; i++) {
        CGFloat r = bub[i][2] * (w / 320.0f);
        CGPoint ctr = CGPointMake(w * bub[i][0], h * bub[i][1]);
        CGRect rect = CGRectMake(ctr.x - r, ctr.y - r, r * 2, r * 2);
        CGContextSaveGState(c);
        CGContextAddEllipseInRect(c, rect);
        CGContextClip(c);
        Radial(c, ctr, r, RGBA(255, 255, 255, 0.04f), RGBA(210, 246, 255, 0.50f));
        CGContextRestoreGState(c);
        [RGBA(255, 255, 255, 0.70f) setStroke];
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(rect, 0.5f, 0.5f)];
        ring.lineWidth = 1.0f;
        [ring stroke];
        [RGBA(255, 255, 255, 0.85f) setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(ctr.x - r * 0.55f, ctr.y - r * 0.72f, r * 0.62f, r * 0.34f)] fill];
        [RGBA(255, 255, 255, 0.35f) setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(ctr.x + r * 0.05f, ctr.y + r * 0.28f, r * 0.55f, r * 0.34f)] fill];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

/* Tło: teksturowane, delikatne poziome "szczotkowane" linie (metal) albo prążki (grafit). */
UIColor *ACBackgroundColor(void)
{
    NSInteger t = ACCurrentTheme();
    if (!gBgCache[t] && ACP()->metal) {
        const ACPalette *p = ACP();
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(192, 96), YES, 0.0f);
        [ACRGB(p->bg, 1) setFill];
        UIRectFill(CGRectMake(0, 0, 192, 96));
        [ACBrushedOverlay() drawAtPoint:CGPointZero];
        UIImage *tile = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        gBgCache[t] = [UIColor colorWithPatternImage:tile];
    }
    if (!gBgCache[t]) {
        const ACPalette *p = ACP();
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(8, 4), YES, 0.0f);
        [ACRGB(p->bg, 1) setFill];
        UIRectFill(CGRectMake(0, 0, 8, 4));
        [ACRGB(p->bgHi, 1) setFill];
        UIRectFill(CGRectMake(0, 1, 8, 1));
        [ACRGB(p->bgLo, 1) setFill];
        UIRectFill(CGRectMake(0, 3, 8, 1));
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        gBgCache[t] = [UIColor colorWithPatternImage:img];
    }
    return gBgCache[t];
}

UIView *ACBackgroundView(CGRect frame)
{
    if (ACP()->aero) {
        NSInteger t = ACCurrentTheme();
        CGSize screen = [[UIScreen mainScreen] bounds].size;
        if (!gSkyCache[t] || gSkySize.width != screen.width || gSkySize.height != screen.height) {
            for (int i = 0; i < NTHEMES; i++) gSkyCache[i] = nil;
            gSkySize = screen;
            gSkyCache[t] = AeroSkyImage(screen);
        }
        UIImageView *iv = [[UIImageView alloc] initWithFrame:frame];
        iv.image = gSkyCache[t];
        iv.contentMode = UIViewContentModeScaleToFill;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        return iv;
    }
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = ACBackgroundColor();
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return v;
}

/* ---------- paski ---------- */

/* Błyszczący pasek: jasna górna połowa (odbicie), ciemna dolna. W Aero dodatkowo szklany połysk i poświata. */
static UIImage *BarImage(CGFloat height)
{
    const ACPalette *p = ACP();
    if (p->metal) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(192.0f, height), NO, 0.0f);
        CGContextRef c = UIGraphicsGetCurrentContext();
        NSArray *cols = [NSArray arrayWithObjects:(__bridge id)ACRGB(p->barT1, 1).CGColor, (__bridge id)ACRGB(p->barT2, 1).CGColor,
                         (__bridge id)ACRGB(p->barB1, 1).CGColor, (__bridge id)ACRGB(p->barB2, 1).CGColor, nil];
        static const CGFloat locs[4] = { 0.0f, 0.5f, 0.5001f, 1.0f };
        ACMetalFill(c, CGRectMake(0, 0, 192, height), cols, locs, 0.9f);
        [RGBA(255, 255, 255, 1) setFill];
        CGContextSetAlpha(c, 0.85f);
        CGContextFillRect(c, CGRectMake(0, 0, 192, 1));
        CGContextSetAlpha(c, 1.0f);
        [RGBA(70, 76, 88, 1) setFill];
        CGContextFillRect(c, CGRectMake(0, height - 1, 192, 1));
        UIImage *mimg = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [mimg resizableImageWithCapInsets:UIEdgeInsetsZero resizingMode:UIImageResizingModeTile];
    }
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(4.0f, height), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGFloat half = (CGFloat)((int)(height / 2.0f));
    Fill(c, CGRectMake(0, 0, 4, half), ACRGB(p->barT1, 1), ACRGB(p->barT2, 1));
    Fill(c, CGRectMake(0, half, 4, height - half), ACRGB(p->barB1, 1), ACRGB(p->barB2, 1));
    if (p->aero) {
        Fill(c, CGRectMake(0, 0, 4, half), RGBA(255, 255, 255, 0.42f), RGBA(255, 255, 255, 0.04f));
        Fill(c, CGRectMake(0, half, 4, height - half), RGBA(255, 255, 255, 0.0f), RGBA(180, 240, 255, 0.28f));
    }
    [RGBA(255, 255, 255, 1) setFill];
    CGContextSetAlpha(c, p->aero ? 0.75f : 0.35f);
    CGContextFillRect(c, CGRectMake(0, 0, 4, 1));
    CGContextSetAlpha(c, 1.0f);
    [RGBA(p->aero ? 0 : 0, p->aero ? 40 : 0, p->aero ? 90 : 0, p->aero ? 0.65f : 0.7f) setFill];
    CGContextFillRect(c, CGRectMake(0, height - 1, 4, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(0, 1, 0, 1)];
}

static UIImage *SelectionImage(void)
{
    const ACPalette *p = ACP();
    if (p->metal) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(20.0f, 49.0f), NO, 0.0f);
        [RGBA(255, 255, 255, 0.7f) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 4, 16, 43) cornerRadius:6] fill];
        [RGBA(60, 66, 78, 0.34f) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 3, 16, 43) cornerRadius:6] fill];
        UIImage *mi = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [mi resizableImageWithCapInsets:UIEdgeInsetsMake(12, 9, 12, 9)];
    }
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(20.0f, 49.0f), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (p->aero) {
        /* świecąca szklana pastylka */
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 3, 16, 43) cornerRadius:7];
        CGContextSaveGState(c);
        [shape addClip];
        Fill(c, CGRectMake(0, 3, 20, 43), RGBA(255, 255, 255, 0.62f), RGBA(150, 226, 255, 0.28f));
        Fill(c, CGRectMake(0, 3, 20, 20), RGBA(255, 255, 255, 0.45f), RGBA(255, 255, 255, 0.05f));
        CGContextRestoreGState(c);
        [RGBA(255, 255, 255, 0.8f) setStroke];
        shape.lineWidth = 1.0f;
        [shape stroke];
    } else {
        [RGBA(255, 255, 255, p->light ? 0.24f : 0.16f) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 3, 16, 43) cornerRadius:6] fill];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(12, 9, 12, 9)];
}

void ACStyleNavigationBar(UINavigationBar *bar)
{
    const ACPalette *p = ACP();
    [bar setBackgroundImage:BarImage(44.0f) forBarMetrics:UIBarMetricsDefault];
    bar.tintColor = ACRGB(p->barTint, 1);
    if (p->metal) {
        bar.titleTextAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
            RGBA(58, 62, 70, 1), UITextAttributeTextColor,
            [UIColor colorWithWhite:1.0f alpha:0.9f], UITextAttributeTextShadowColor,
            [NSValue valueWithUIOffset:UIOffsetMake(0, 1)], UITextAttributeTextShadowOffset,
            [UIFont boldSystemFontOfSize:20.0f], UITextAttributeFont, nil];
    } else {
        UIColor *sh = p->aero ? RGBA(0, 50, 110, 0.85f) : [UIColor colorWithWhite:0.0f alpha:0.85f];
        bar.titleTextAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
            [UIColor whiteColor], UITextAttributeTextColor, sh, UITextAttributeTextShadowColor,
            [NSValue valueWithUIOffset:UIOffsetMake(0, -1)], UITextAttributeTextShadowOffset,
            [UIFont boldSystemFontOfSize:20.0f], UITextAttributeFont, nil];
    }
    NSDictionary *btn = p->metal
        ? [NSDictionary dictionaryWithObjectsAndKeys:RGBA(40, 45, 54, 1), UITextAttributeTextColor,
              [UIColor colorWithWhite:1.0f alpha:0.85f], UITextAttributeTextShadowColor,
              [NSValue valueWithUIOffset:UIOffsetMake(0, 1)], UITextAttributeTextShadowOffset, nil]
        : [NSDictionary dictionaryWithObjectsAndKeys:[UIColor whiteColor], UITextAttributeTextColor,
              [UIColor colorWithWhite:0.0f alpha:0.45f], UITextAttributeTextShadowColor,
              [NSValue valueWithUIOffset:UIOffsetMake(0, -1)], UITextAttributeTextShadowOffset, nil];
    [[UIBarButtonItem appearance] setTitleTextAttributes:btn forState:UIControlStateNormal];
}

void ACStyleTabBar(UITabBar *bar)
{
    bar.backgroundImage = BarImage(49.0f);
    bar.selectionIndicatorImage = SelectionImage();
}

/* ---------- ikony zakładek (maski) ---------- */

UIImage *ACTabIcon(int kind)
{
    CGFloat s = 30.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    [[UIColor blackColor] setFill];
    [[UIColor blackColor] setStroke];
    if (kind == 0) {                       /* dymek z trzema kropkami = czaty */
        UIBezierPath *bub = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2.5f, 4, 25, 18) cornerRadius:7];
        [bub fill];
        UIBezierPath *tail = [UIBezierPath bezierPath];
        [tail moveToPoint:CGPointMake(8, 20)];
        [tail addLineToPoint:CGPointMake(6.5f, 27.5f)];
        [tail addLineToPoint:CGPointMake(15, 21.5f)];
        [tail closePath];
        [tail fill];
        CGContextSetBlendMode(c, kCGBlendModeClear);
        for (int i = 0; i < 3; i++) [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(8.2f + i * 5.6f, 11.0f, 3.6f, 3.6f)] fill];
        CGContextSetBlendMode(c, kCGBlendModeNormal);
    } else if (kind == 1) {                /* głowa i ramiona = kontakty */
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(9.5f, 3.5f, 11, 11)] fill];
        UIBezierPath *body = [UIBezierPath bezierPath];
        [body moveToPoint:CGPointMake(3.5f, 27)];
        [body addCurveToPoint:CGPointMake(15, 16.5f) controlPoint1:CGPointMake(3.5f, 19.5f) controlPoint2:CGPointMake(8.5f, 16.5f)];
        [body addCurveToPoint:CGPointMake(26.5f, 27) controlPoint1:CGPointMake(21.5f, 16.5f) controlPoint2:CGPointMake(26.5f, 19.5f)];
        [body closePath];
        [body fill];
    } else {                               /* suwaki = ustawienia */
        static const CGFloat knob[3] = { 19, 9, 16 };
        for (int i = 0; i < 3; i++) {
            CGFloat y = 7.0f + i * 8.0f;
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, y + 1.5f, 24, 2.5f) cornerRadius:1.2f] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(knob[i] - 3.5f, y - 0.5f, 7, 7)] fill];
        }
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static UIImage *TabIconTinted(int kind, UIColor *color)
{
    UIImage *mask = ACTabIcon(kind);
    CGRect r = CGRectMake(0, 0, mask.size.width, mask.size.height);
    UIGraphicsBeginImageContextWithOptions(r.size, NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    [mask drawInRect:r];
    CGContextSetBlendMode(c, kCGBlendModeSourceIn);
    [color setFill];
    CGContextFillRect(c, r);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!ACP()->metal) return img;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(r.size.width, r.size.height + 1.0f), NO, 0.0f);
    c = UIGraphicsGetCurrentContext();
    CGContextSaveGState(c);
    [mask drawInRect:CGRectMake(0, 1, r.size.width, r.size.height)];
    CGContextSetBlendMode(c, kCGBlendModeSourceIn);
    [RGBA(255, 255, 255, 0.85f) setFill];
    CGContextFillRect(c, CGRectMake(0, 0, r.size.width, r.size.height + 1.0f));
    CGContextRestoreGState(c);
    [img drawInRect:CGRectMake(0, 0, r.size.width, r.size.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

void ACStyleTabItem(UITabBarItem *item, int kind)
{
    const ACPalette *p = ACP();
    UIColor *off = ACRGB(p->tabOff, 1);
    UIColor *on = ACRGB(p->tabOn, 1);
    [item setFinishedSelectedImage:TabIconTinted(kind, on) withFinishedUnselectedImage:TabIconTinted(kind, off)];
    BOOL metal = p->metal;
    NSValue *offset = [NSValue valueWithUIOffset:UIOffsetMake(0, metal ? 1 : -1)];
    UIColor *shadow = metal ? [UIColor colorWithWhite:1.0f alpha:0.85f] : (p->aero ? RGBA(0, 50, 110, 0.8f) : [UIColor colorWithWhite:0.0f alpha:0.8f]);
    [item setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:off, UITextAttributeTextColor, shadow, UITextAttributeTextShadowColor, offset, UITextAttributeTextShadowOffset, nil] forState:UIControlStateNormal];
    [item setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:on, UITextAttributeTextColor, shadow, UITextAttributeTextShadowColor, offset, UITextAttributeTextShadowOffset, nil] forState:UIControlStateSelected];
}

void ACStyleTable(UITableView *table)
{
    table.backgroundView = ACBackgroundView(table.bounds);
    table.backgroundColor = [UIColor clearColor];
    table.separatorColor = ACP()->aero ? RGBA(255, 255, 255, 0.55f) : ACRGB(ACP()->sep, 1);
}

/* ---------- błyszczące przyciski ("żel") ---------- */

UIImage *ACGelImage(int style)
{
    NSInteger th = ACCurrentTheme();
    if (style < 0 || style > 3) style = 1;
    if (ACP()->metal && style <= 1) return ACChromeImage();
    if (gGelCache[th][style]) return gGelCache[th][style];
    const ACPalette *p = ACP();
    int top[3], bot[3], border[3];
    switch (style) {
        case 0:  Copy3(top, p->accentGelT); Copy3(bot, p->accentGelB); Copy3(border, p->accentGelBorder); break;
        case 2:  SET(top, 235, 90, 90);  SET(bot, 170, 20, 30); SET(border, 90, 8, 14); break;
        case 3:  SET(top, 130, 215, 100); SET(bot, 48, 150, 40); SET(border, 20, 80, 18); break;
        default: Copy3(top, p->neutT); Copy3(bot, p->neutB); Copy3(border, p->neutBorder); break;
    }
    CGFloat w = 24.0f, h = 44.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0.5f, 0.5f, w - 1.0f, h - 1.5f);
    CGFloat radius = p->aero ? 12.0f : 9.0f;
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
    CGContextSaveGState(c);
    [shape addClip];
    Fill(c, CGRectMake(0, 0, w, h), RGBA(top[0], top[1], top[2], 1), RGBA(bot[0], bot[1], bot[2], 1));
    Fill(c, CGRectMake(0, 0, w, h * 0.5f), RGBA(255, 255, 255, p->aero ? 0.70f : 0.55f), RGBA(255, 255, 255, p->aero ? 0.16f : 0.10f));
    if (p->aero) Fill(c, CGRectMake(0, h * 0.5f, w, h * 0.5f), RGBA(255, 255, 255, 0.0f), RGBA(210, 250, 255, 0.40f));
    CGContextRestoreGState(c);
    [RGBA(border[0], border[1], border[2], 1) setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    if (p->aero) {
        UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, 1.0f, 1.0f) cornerRadius:radius - 1.0f];
        [RGBA(255, 255, 255, 0.55f) setStroke];
        rim.lineWidth = 0.8f;
        [rim stroke];
    }
    [RGBA(255, 255, 255, 0.18f) setFill];
    CGContextFillRect(c, CGRectMake(6, h - 1, w - 12, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    gGelCache[th][style] = [img resizableImageWithCapInsets:UIEdgeInsetsMake(14, 11, 14, 11)];
    return gGelCache[th][style];
}

/* mała próbka motywu do listy w ustawieniach */
UIImage *ACThemeSwatch(NSInteger index)
{
    ACPalette p;
    if (index < 0 || index >= NTHEMES) index = 0;
    BuildPalette(index, &p);
    CGFloat s = 34.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(1.5f, 1.5f, s - 3.0f, s - 3.0f);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:9.0f];
    CGContextSaveGState(c);
    [shape addClip];
    if (p.metal) {
        int t1[3] = { 250, 251, 252 }, t2[3] = { 196, 202, 210 }, b1[3] = { 150, 157, 168 }, b2[3] = { 222, 226, 232 };
        if (p.tintAmt > 0) { Mix(t1, t1, p.tint, p.tintAmt); Mix(t2, t2, p.tint, p.tintAmt); Mix(b1, b1, p.tint, p.tintAmt); Mix(b2, b2, p.tint, p.tintAmt); }
        Fill(c, CGRectMake(0, 0, s, s * 0.5f), ACRGB(t1, 1), ACRGB(t2, 1));
        Fill(c, CGRectMake(0, s * 0.5f, s, s * 0.5f), ACRGB(b1, 1), ACRGB(b2, 1));
    } else if (p.aero) {
        Fill(c, CGRectMake(0, 0, s, s), ACRGB(p.skyT, 1), ACRGB(p.skyB, 1));
        Radial(c, CGPointMake(s * 0.78f, s * 0.22f), s * 0.6f, RGBA(255, 255, 255, 0.8f), RGBA(255, 255, 255, 0));
        UIBezierPath *hill = [UIBezierPath bezierPath];
        [hill moveToPoint:CGPointMake(0, s * 0.74f)];
        [hill addCurveToPoint:CGPointMake(s, s * 0.70f) controlPoint1:CGPointMake(s * 0.35f, s * 0.52f) controlPoint2:CGPointMake(s * 0.7f, s * 0.9f)];
        [hill addLineToPoint:CGPointMake(s, s)];
        [hill addLineToPoint:CGPointMake(0, s)];
        [hill closePath];
        CGContextSaveGState(c);
        [hill addClip];
        Fill(c, CGRectMake(0, s * 0.5f, s, s * 0.5f), ACRGB(p.hillT, 1), ACRGB(p.hillB, 1));
        CGContextRestoreGState(c);
        Fill(c, CGRectMake(0, 0, s, s * 0.5f), RGBA(255, 255, 255, 0.40f), RGBA(255, 255, 255, 0.05f));
    } else {
        Fill(c, CGRectMake(0, 0, s, s), ACRGB(p.accentGelT, 1), ACRGB(p.accentGelB, 1));
        Fill(c, CGRectMake(0, 0, s, s * 0.5f), RGBA(255, 255, 255, 0.55f), RGBA(255, 255, 255, 0.10f));
    }
    CGContextRestoreGState(c);
    [(p.metal ? RGBA(84, 90, 101, 1) : (p.aero ? RGBA(40, 110, 170, 1) : ACRGB(p.accentGelBorder, 1))) setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

UIActivityIndicatorViewStyle ACSpinnerStyle(void)
{
    return ACP()->metal ? UIActivityIndicatorViewStyleGray : UIActivityIndicatorViewStyleWhite;
}

UIColor *ACGlyphColor(void)
{
    return ACP()->metal ? ACRGB(ACP()->chromeText, 1) : [UIColor whiteColor];
}

UIButton *ACGelButton(NSString *title, int style, CGRect frame)
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    [b setBackgroundImage:ACGelImage(style) forState:UIControlStateNormal];
    [b setTitle:title forState:UIControlStateNormal];
    if (ACP()->metal && style <= 1) {
        [b setTitleColor:ACRGB(ACP()->chromeText, 1) forState:UIControlStateNormal];
        [b setTitleShadowColor:[UIColor colorWithWhite:1.0f alpha:0.9f] forState:UIControlStateNormal];
        b.titleLabel.shadowOffset = CGSizeMake(0, 1);
    } else {
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [b setTitleShadowColor:(ACP()->aero ? RGBA(0, 50, 110, 0.7f) : [UIColor colorWithWhite:0.0f alpha:0.6f]) forState:UIControlStateNormal];
        b.titleLabel.shadowOffset = CGSizeMake(0, -1);
    }
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17.0f];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.65f;
    b.adjustsImageWhenHighlighted = YES;
    return b;
}

UIBarButtonItem *ACBarButton(NSString *title, id target, SEL action)
{
    return [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStyleBordered target:target action:action];
}

/* ---------- elementy rozmowy ---------- */

/* Szklana kula z inicjałami; kolor zależy od imienia. */
UIImage *ACAvatarImage(NSString *name, CGFloat d)
{
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%ld|%@|%d", (long)ACCurrentTheme(), name, (int)d];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    static const int pal[8][3] = { { 36, 150, 235 }, { 64, 184, 84 }, { 242, 150, 28 }, { 224, 72, 96 },
                                   { 150, 100, 220 }, { 24, 176, 176 }, { 230, 190, 30 }, { 120, 132, 150 } };
    unsigned int h = 5381u;
    for (NSUInteger i = 0; i < [name length]; i++) h = h * 33u + (unsigned int)[name characterAtIndex:i];
    const int *col = pal[(h >> 3) & 7];
    const ACPalette *p = ACP();

    NSMutableString *ini = [NSMutableString string];
    NSArray *words = [name componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *w in words) {
        if ([w length] && [ini length] < 2) [ini appendString:[[w substringToIndex:1] uppercaseString]];
    }
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(d, d), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect all = CGRectMake(0, 0, d, d);
    /* pierścień: chrom, szkło albo ciemny metal */
    CGRect ring = CGRectInset(all, 1.0f, 1.0f);
    CGContextSaveGState(c);
    CGContextAddEllipseInRect(c, ring);
    CGContextClip(c);
    if (p->metal) Fill(c, ring, RGBA(252, 252, 253, 1), RGBA(150, 157, 168, 1));
    else if (p->aero) Fill(c, ring, RGBA(255, 255, 255, 1), RGBA(150, 214, 245, 1));
    else Fill(c, ring, RGBA(150, 154, 164, 1), RGBA(34, 36, 40, 1));
    CGContextRestoreGState(c);
    CGFloat ins = d * 0.065f + 1.0f;
    CGRect orb = CGRectInset(all, ins, ins);
    CGContextSaveGState(c);
    CGContextAddEllipseInRect(c, orb);
    CGContextClip(c);
    int top[3], bot[3];
    Mix(top, col, (const int[3]){ 255, 255, 255 }, 0.35f);
    Mix(bot, col, (const int[3]){ 0, 0, 0 }, 0.30f);
    Fill(c, orb, ACRGB(top, 1), ACRGB(bot, 1));
    Radial(c, CGPointMake(orb.origin.x + orb.size.width * 0.5f, orb.origin.y + orb.size.height * 1.05f), orb.size.width * 0.7f,
           RGBA(255, 255, 255, 0.40f), RGBA(255, 255, 255, 0.0f));
    CGContextRestoreGState(c);
    /* połysk na górze kuli */
    CGRect gloss = CGRectMake(orb.origin.x + orb.size.width * 0.12f, orb.origin.y + orb.size.height * 0.05f,
                              orb.size.width * 0.76f, orb.size.height * 0.46f);
    CGContextSaveGState(c);
    CGContextAddEllipseInRect(c, gloss);
    CGContextClip(c);
    Fill(c, gloss, RGBA(255, 255, 255, 0.82f), RGBA(255, 255, 255, 0.12f));
    CGContextRestoreGState(c);
    [RGBA(0, 0, 0, 0.45f) setStroke];
    UIBezierPath *edge = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(orb, 0.25f, 0.25f)];
    edge.lineWidth = 0.7f;
    [edge stroke];
    /* inicjały */
    UIFont *font = [UIFont boldSystemFontOfSize:d * 0.38f];
    CGSize sz = [ini sizeWithFont:font];
    CGRect tr = CGRectMake(0, (d - sz.height) / 2.0f + d * 0.02f, d, sz.height);
    CGContextSetRGBFillColor(c, 0, 0, 0, 0.35f);
    [ini drawInRect:CGRectOffset(tr, 0, -1) withFont:font lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
    CGContextSetRGBFillColor(c, 1, 1, 1, 1);
    [ini drawInRect:tr withFont:font lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [cache setObject:img forKey:key];
    return img;
}

UIImage *ACBubbleImage(BOOL outgoing)
{
    const ACPalette *p = ACP();
    CGFloat w = 34.0f, h = 36.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0.5f, 0.5f, w - 1.0f, h - 2.0f);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:15.0f];
    int top[3], bot[3], border[3];
    if (outgoing) {
        Copy3(top, p->accentGelT); Copy3(bot, p->accentGelB); Copy3(border, p->accentGelBorder);
    } else if (p->aero) {
        SET(top, 255, 255, 255); SET(bot, 214, 238, 252); SET(border, 128, 176, 212);
    } else if (p->metal) {
        SET(top, 252, 252, 253); SET(bot, 206, 211, 218); SET(border, 120, 126, 138);
        if (p->tintAmt > 0) { Mix(top, top, p->tint, p->tintAmt * 0.6f); Mix(bot, bot, p->tint, p->tintAmt); }
    } else {
        SET(top, 96, 100, 110); SET(bot, 56, 59, 67); SET(border, 12, 13, 16);
    }
    CGContextSaveGState(c);
    [shape addClip];
    Fill(c, CGRectMake(0, 0, w, h), RGBA(top[0], top[1], top[2], 1), RGBA(bot[0], bot[1], bot[2], 1));
    BOOL glossy = outgoing || p->aero;
    Fill(c, CGRectMake(0, 0, w, h * 0.5f), RGBA(255, 255, 255, glossy ? 0.50f : 0.22f), RGBA(255, 255, 255, glossy ? 0.08f : 0.03f));
    CGContextRestoreGState(c);
    [RGBA(border[0], border[1], border[2], 1) setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(16, 16, 18, 16)];
}

UIColor *ACBubbleTextColor(BOOL outgoing)
{
    const ACPalette *p = ACP();
    if (outgoing) return [UIColor whiteColor];
    return p->light ? ACRGB(p->text, 1) : [UIColor whiteColor];
}

UIImage *ACBadgeImage(void)
{
    CGFloat w = 24.0f, h = 24.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(1.0f, 1.0f, w - 2.0f, h - 3.0f);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:10.0f];
    CGContextSaveGState(c);
    [shape addClip];
    Fill(c, CGRectMake(0, 0, w, h), RGBA(255, 120, 110, 1), RGBA(196, 18, 24, 1));
    Fill(c, CGRectMake(0, 0, w, h * 0.5f), RGBA(255, 255, 255, 0.62f), RGBA(255, 255, 255, 0.10f));
    CGContextRestoreGState(c);
    [RGBA(255, 255, 255, 1) setStroke];
    shape.lineWidth = 1.5f;
    [shape stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(10, 11, 10, 11)];
}

UIImage *ACInputFieldImage(void)
{
    const ACPalette *p = ACP();
    CGFloat w = 30.0f, h = 32.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0f);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0.5f, 1.0f, w - 1.0f, h - 2.0f);
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:14.0f];
    CGContextSaveGState(c);
    [shape addClip];
    Fill(c, CGRectMake(0, 0, w, h), ACRGB(p->fieldT, 1), ACRGB(p->fieldB, 1));
    Fill(c, CGRectMake(0, 0, w, 6), RGBA(0, 0, 0, p->light ? 0.22f : 0.5f), RGBA(0, 0, 0, 0.0f));
    CGContextRestoreGState(c);
    [RGBA(0, 0, 0, p->light ? 0.45f : 0.8f) setStroke];
    shape.lineWidth = 1.0f;
    [shape stroke];
    [RGBA(255, 255, 255, p->light ? 0.9f : 0.18f) setFill];
    CGContextFillRect(c, CGRectMake(8, h - 1, w - 16, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(15, 15, 15, 15)];
}

UIImage *ACInputBarImage(void)
{
    return BarImage(44.0f);
}
