#import "ACMedia.h"

static NSString *Str(id o) { return [o isKindOfClass:[NSString class]] ? o : @""; }
static NSDictionary *Dict(id o) { return [o isKindOfClass:[NSDictionary class]] ? o : nil; }
static NSArray *Arr(id o) { return [o isKindOfClass:[NSArray class]] ? o : [NSArray array]; }
static int Int(id o) { return [o respondsToSelector:@selector(intValue)] ? [o intValue] : 0; }
static long long Long(id o) { return [o respondsToSelector:@selector(longLongValue)] ? [o longLongValue] : 0; }
static BOOL Bool(id o) { return [o respondsToSelector:@selector(boolValue)] ? [o boolValue] : NO; }

#define MAX_IMG_SIDE 204

@implementation ACMedia

+ (NSString *)cacheDirectory
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[dirs objectAtIndex:0] stringByAppendingPathComponent:@"AeroChat"];
}

+ (NSString *)sizeString:(int)bytes
{
    if (bytes <= 0) return @"";
    if (bytes < 1024) return [NSString stringWithFormat:@"%d B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%d KB", bytes / 1024];
    float mb = (float)bytes / 1048576.0f;
    return [[NSString stringWithFormat:@"%.1f MB", mb] stringByReplacingOccurrencesOfString:@"." withString:@","];
}

+ (NSString *)durationString:(int)s
{
    if (s < 0) s = 0;
    if (s >= 3600) return [NSString stringWithFormat:@"%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60];
    return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

/* wybór miniatury i największego rozsądnego rozmiaru ze zbioru photoSize / photoCachedSize / photoSizeProgressive */
static void PickSizes(NSArray *sizes, NSString **thumbType, int *tw, int *th, NSString **fullType, int *fullSize)
{
    NSString *bestThumb = nil, *fallbackThumb = nil, *bestFull = nil, *smallestAll = nil;
    int btW = 0, btH = 0, fbW = 0, fbH = 0, bfSize = 0, bfMax = 0, smMax = 0x7fffffff, smSize = 0;
    for (id o in sizes) {
        NSDictionary *s = Dict(o);
        NSString *k = Str([s objectForKey:@"_"]);
        BOOL sized = [k isEqualToString:@"photoSize"] || [k isEqualToString:@"photoCachedSize"] || [k isEqualToString:@"photoSizeProgressive"];
        if (!sized) continue;
        NSString *type = Str([s objectForKey:@"type"]);
        if (![type length]) continue;
        int w = Int([s objectForKey:@"w"]), h = Int([s objectForKey:@"h"]);
        int mx = w > h ? w : h;
        if (mx <= 0) continue;
        int sz = 0;
        if ([k isEqualToString:@"photoSize"]) sz = Int([s objectForKey:@"size"]);
        else if ([k isEqualToString:@"photoCachedSize"]) sz = (int)([Str([s objectForKey:@"bytes"]) length] / 2);
        else { NSArray *a = Arr([s objectForKey:@"sizes"]); if ([a count]) sz = Int([a lastObject]); }
        if (mx >= 200) {
            if (!bestThumb || mx < (btW > btH ? btW : btH)) { bestThumb = type; btW = w; btH = h; }
        } else {
            if (!fallbackThumb || mx > (fbW > fbH ? fbW : fbH)) { fallbackThumb = type; fbW = w; fbH = h; }
        }
        if (mx <= 1600 && mx > bfMax) { bestFull = type; bfMax = mx; bfSize = sz; }
        if (mx < smMax) { smallestAll = type; smMax = mx; smSize = sz; }
    }
    if (bestThumb) { if (thumbType) *thumbType = bestThumb; if (tw) *tw = btW; if (th) *th = btH; }
    else if (fallbackThumb) { if (thumbType) *thumbType = fallbackThumb; if (tw) *tw = fbW; if (th) *th = fbH; }
    if (bestFull) { if (fullType) *fullType = bestFull; if (fullSize) *fullSize = bfSize; }
    else if (smallestAll) { if (fullType) *fullType = smallestAll; if (fullSize) *fullSize = smSize; }
}

+ (ACMedia *)mediaFromJSON:(NSDictionary *)md
{
    NSString *t = Str([md objectForKey:@"_"]);
    ACMedia *m = [[ACMedia alloc] init];
    if ([t isEqualToString:@"messageMediaPhoto"]) {
        NSDictionary *p = Dict([md objectForKey:@"photo"]);
        if (![Str([p objectForKey:@"_"]) isEqualToString:@"photo"]) return nil;
        m.kind = ACMediaPhoto;
        m.isDocument = NO;
        m.mediaId = Long([p objectForKey:@"id"]);
        m.accessHash = Long([p objectForKey:@"access_hash"]);
        m.fileRef = Str([p objectForKey:@"file_reference"]);
        m.dc = Int([p objectForKey:@"dc_id"]);
        NSString *tt = nil, *ft = nil;
        int tw = 0, th = 0, fs = 0;
        PickSizes(Arr([p objectForKey:@"sizes"]), &tt, &tw, &th, &ft, &fs);
        m.thumbType = tt; m.w = tw; m.h = th; m.fullType = ft; m.size = fs;
        if (![m.fullType length]) return nil;
        return m;
    }
    if ([t isEqualToString:@"messageMediaDocument"]) {
        NSDictionary *d = Dict([md objectForKey:@"document"]);
        if (![Str([d objectForKey:@"_"]) isEqualToString:@"document"]) return nil;
        m.isDocument = YES;
        m.mediaId = Long([d objectForKey:@"id"]);
        m.accessHash = Long([d objectForKey:@"access_hash"]);
        m.fileRef = Str([d objectForKey:@"file_reference"]);
        m.dc = Int([d objectForKey:@"dc_id"]);
        m.mime = Str([d objectForKey:@"mime_type"]);
        long long sz = Long([d objectForKey:@"size"]);
        m.size = sz > 2147483647LL ? 2147483647 : (int)sz;
        BOOL video = NO, round = NO, voice = NO, audio = NO, sticker = NO, animated = NO;
        int vw = 0, vh = 0;
        for (id o in Arr([d objectForKey:@"attributes"])) {
            NSDictionary *a = Dict(o);
            NSString *k = Str([a objectForKey:@"_"]);
            if ([k isEqualToString:@"documentAttributeFilename"]) m.fileName = Str([a objectForKey:@"file_name"]);
            else if ([k isEqualToString:@"documentAttributeVideo"]) {
                video = YES; round = Bool([a objectForKey:@"round_message"]);
                vw = Int([a objectForKey:@"w"]); vh = Int([a objectForKey:@"h"]);
                m.duration = Int([a objectForKey:@"duration"]);
            } else if ([k isEqualToString:@"documentAttributeAudio"]) {
                audio = YES; voice = Bool([a objectForKey:@"voice"]);
                m.duration = Int([a objectForKey:@"duration"]);
                m.title = Str([a objectForKey:@"title"]);
                m.performer = Str([a objectForKey:@"performer"]);
            } else if ([k isEqualToString:@"documentAttributeSticker"]) {
                sticker = YES; m.alt = Str([a objectForKey:@"alt"]);
            } else if ([k isEqualToString:@"documentAttributeAnimated"]) animated = YES;
            else if ([k isEqualToString:@"documentAttributeImageSize"]) { vw = Int([a objectForKey:@"w"]); vh = Int([a objectForKey:@"h"]); }
        }
        if (!video && !audio && !sticker && [m.mime hasPrefix:@"video/"]) video = YES;
        if (!video && !audio && !sticker && [m.mime hasPrefix:@"audio/"]) audio = YES;
        if (sticker) m.kind = ACMediaSticker;
        else if (voice) m.kind = ACMediaVoice;
        else if (audio) m.kind = ACMediaAudio;
        else if (round) m.kind = ACMediaRound;
        else if (video || animated) m.kind = ACMediaVideo;
        else m.kind = ACMediaFile;
        if (m.kind != ACMediaSticker && m.kind != ACMediaVoice) {
            NSString *tt = nil;
            int tw = 0, th = 0;
            PickSizes(Arr([d objectForKey:@"thumbs"]), &tt, &tw, &th, NULL, NULL);
            m.thumbType = tt;
            m.w = tw; m.h = th;
            if (vw > 0 && vh > 0 && tt) { m.w = vw; m.h = vh; }
        }
        return m;
    }
    return nil;
}

- (BOOL)hasImageArea
{
    return _kind != ACMediaSticker && [_thumbType length] && _w > 0 && _h > 0 && _thumbState != 3;
}

- (CGSize)imageSize
{
    if (![self hasImageArea]) return CGSizeZero;
    float w = (float)_w, h = (float)_h;
    float m = w > h ? w : h;
    float k = (float)MAX_IMG_SIDE / m;
    if (k > 1.0f) k = 1.0f;
    float rw = w * k, rh = h * k;
    if (rw < 60.0f) rw = 60.0f;
    if (rh < 40.0f) rh = 40.0f;
    return CGSizeMake((CGFloat)((int)rw), (CGFloat)((int)rh));
}

- (NSString *)displayName
{
    if ([_fileName length]) return _fileName;
    return @"plik";
}

- (NSString *)label
{
    switch (_kind) {
        case ACMediaPhoto: return @"[Zdjęcie]";
        case ACMediaVideo: return _duration > 0 ? [NSString stringWithFormat:@"[Wideo %@]", [ACMedia durationString:_duration]] : @"[Wideo]";
        case ACMediaRound: return _duration > 0 ? [NSString stringWithFormat:@"[Wideo-wiadomość %@]", [ACMedia durationString:_duration]] : @"[Wideo-wiadomość]";
        case ACMediaVoice: return _duration > 0 ? [NSString stringWithFormat:@"[Wiadomość głosowa %@]", [ACMedia durationString:_duration]] : @"[Wiadomość głosowa]";
        case ACMediaAudio: {
            NSString *n = [_title length] ? ([_performer length] ? [NSString stringWithFormat:@"%@ – %@", _performer, _title] : _title) : [self displayName];
            return [NSString stringWithFormat:@"[Audio] %@%@", n, _duration > 0 ? [@" " stringByAppendingString:[ACMedia durationString:_duration]] : @""];
        }
        case ACMediaSticker: return [NSString stringWithFormat:@"[Naklejka%@]", [_alt length] ? [@" " stringByAppendingString:_alt] : @""];
        default: {
            NSString *sz = [ACMedia sizeString:_size];
            return [NSString stringWithFormat:@"[Plik] %@%@", [self displayName], [sz length] ? [NSString stringWithFormat:@" (%@)", sz] : @""];
        }
    }
}

- (NSString *)progressText
{
    return [NSString stringWithFormat:@"Pobieranie %d%%", (int)(_progress * 100.0f)];
}

- (NSString *)statusLine
{
    if (_kind == ACMediaSticker) return nil;
    if (_state == ACMediaLoading) return [self progressText];
    if (_state == ACMediaFailed) return @"Błąd, dotknij, aby ponowić";
    if (_state == ACMediaDone) return @"Dotknij, aby otworzyć";
    return @"Dotknij, aby pobrać";
}

- (NSString *)overlayText
{
    if (_state == ACMediaLoading) return [self progressText];
    if (_state == ACMediaFailed) return @"Błąd, dotknij, aby ponowić";
    if (_kind == ACMediaVideo || _kind == ACMediaRound) {
        NSString *s = _duration > 0 ? [@"Wideo " stringByAppendingString:[ACMedia durationString:_duration]] : @"Wideo";
        NSString *sz = [ACMedia sizeString:_size];
        return [sz length] ? [NSString stringWithFormat:@"%@ · %@", s, sz] : s;
    }
    return nil;
}

- (BOOL)needsOtherApp
{
    NSString *m = [_mime lowercaseString];
    if (_kind == ACMediaVoice) return YES;
    if ([m isEqualToString:@"image/webp"] || [m isEqualToString:@"video/webm"] || [m isEqualToString:@"video/x-matroska"]) return YES;
    if ([m hasPrefix:@"audio/ogg"] || [m hasPrefix:@"audio/opus"] || [m isEqualToString:@"audio/flac"] || [m isEqualToString:@"audio/x-flac"]) return YES;
    if ([m isEqualToString:@"video/x-msvideo"] || [m isEqualToString:@"application/x-tgsticker"]) return YES;
    return NO;
}

- (BOOL)canOpen { return _kind != ACMediaSticker; }

- (NSString *)safeName
{
    NSString *n = [_fileName length] ? _fileName : nil;
    if (!n) {
        NSString *ext = @"bin";
        NSString *m = [_mime lowercaseString];
        if (_kind == ACMediaPhoto || [m isEqualToString:@"image/jpeg"]) ext = @"jpg";
        else if ([m isEqualToString:@"image/png"]) ext = @"png";
        else if ([m isEqualToString:@"image/gif"]) ext = @"gif";
        else if ([m isEqualToString:@"video/mp4"]) ext = @"mp4";
        else if ([m isEqualToString:@"video/quicktime"]) ext = @"mov";
        else if ([m isEqualToString:@"audio/mpeg"]) ext = @"mp3";
        else if ([m isEqualToString:@"audio/mp4"] || [m isEqualToString:@"audio/x-m4a"]) ext = @"m4a";
        else if ([m hasPrefix:@"audio/ogg"]) ext = @"ogg";
        else if ([m isEqualToString:@"application/pdf"]) ext = @"pdf";
        else if ([m isEqualToString:@"image/webp"]) ext = @"webp";
        n = [NSString stringWithFormat:@"%@.%@", _kind == ACMediaPhoto ? @"zdjecie" : (_kind == ACMediaVideo || _kind == ACMediaRound ? @"wideo" : (_kind == ACMediaVoice ? @"glosowa" : @"plik")), ext];
    }
    NSMutableString *s = [NSMutableString stringWithString:n];
    [s replaceOccurrencesOfString:@"/" withString:@"_" options:0 range:NSMakeRange(0, [s length])];
    [s replaceOccurrencesOfString:@":" withString:@"_" options:0 range:NSMakeRange(0, [s length])];
    [s replaceOccurrencesOfString:@"\\" withString:@"_" options:0 range:NSMakeRange(0, [s length])];
    if ([s hasPrefix:@"."]) [s insertString:@"_" atIndex:0];
    if ([s length] > 80) {
        NSString *ext = [s pathExtension];
        NSString *base = [s substringToIndex:60];
        s = [NSMutableString stringWithString:[ext length] && [ext length] < 10 ? [base stringByAppendingPathExtension:ext] : base];
    }
    return s;
}

- (NSString *)thumbPath
{
    if (![_thumbType length]) return nil;
    return [[[ACMedia cacheDirectory] stringByAppendingPathComponent:@"t"]
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%lld_%@", _isDocument ? @"d" : @"p", _mediaId, _thumbType]];
}

- (NSString *)fullPath
{
    NSString *dir = [[[ACMedia cacheDirectory] stringByAppendingPathComponent:@"f"]
                     stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%lld", _isDocument ? @"d" : @"p", _mediaId]];
    return [dir stringByAppendingPathComponent:[self safeName]];
}

@end
