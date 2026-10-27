#import <UIKit/UIKit.h>

/* Załącznik wiadomości z Telegrama: zdjęcie albo dokument (wideo, audio, plik, naklejka). */

typedef enum {
    ACMediaPhoto = 1, ACMediaVideo, ACMediaRound, ACMediaAudio, ACMediaVoice, ACMediaSticker, ACMediaFile
} ACMediaKind;

typedef enum { ACMediaIdle = 0, ACMediaLoading, ACMediaDone, ACMediaFailed } ACMediaState;

@interface ACMedia : NSObject
@property (nonatomic) int kind;
@property (nonatomic) BOOL isDocument;
@property (nonatomic) long long mediaId, accessHash;
@property (nonatomic, copy) NSString *fileRef;                 /* file_reference jako hex */
@property (nonatomic) int dc;
@property (nonatomic, copy) NSString *thumbType;               /* rozmiar miniatury (np. "m") albo nil */
@property (nonatomic, copy) NSString *fullType;                /* tylko zdjęcia: rozmiar do pobrania w całości */
@property (nonatomic) int size;                                /* bajty pliku (0 = nieznane) */
@property (nonatomic) int w, h;                                /* proporcje miniatury */
@property (nonatomic) int duration;
@property (nonatomic, copy) NSString *fileName, *mime, *alt, *performer, *title;

/* stan miniatury */
@property (nonatomic, strong) UIImage *thumb;
@property (nonatomic) int thumbState;                          /* 0 brak, 1 pobieranie, 2 gotowa, 3 błąd */
/* stan pobierania pełnego pliku */
@property (nonatomic) int state;
@property (nonatomic) float progress;                          /* 0..1 */
@property (nonatomic, copy) NSString *localPath;
@property (nonatomic, copy) NSString *error;
@property (nonatomic) int thumbTries;                          /* nieudane próby pobrania miniatury */
/* skąd pochodzi (do odświeżenia file_reference po wygaśnięciu) */
@property (nonatomic) int msgId, peerKind;
@property (nonatomic) long long peerId, peerAccess;
@property (nonatomic) int openMode;                            /* po pobraniu: 0 nic, 1 podgląd, 2 "otwórz w…" */

+ (ACMedia *)mediaFromJSON:(NSDictionary *)media;              /* nil, jeśli to nie zdjęcie ani dokument */
+ (NSString *)sizeString:(int)bytes;
+ (NSString *)durationString:(int)seconds;
+ (NSString *)cacheDirectory;

- (BOOL)hasImageArea;                                          /* czy w dymku jest miejsce na miniaturę */
- (CGSize)imageSize;                                           /* rozmiar miniatury w dymku */
- (NSString *)label;                                           /* krótki opis, np. "[Zdjęcie]" */
- (NSString *)statusLine;                                      /* druga linijka dla załączników bez miniatury (albo nil) */
- (NSString *)overlayText;                                     /* napis na miniaturze (albo nil) */
- (BOOL)needsOtherApp;                                         /* format, którego iOS 6 sam nie obsłuży (ogg, webm, webp…) */
- (BOOL)canOpen;                                               /* czy dotknięcie czegokolwiek robi (naklejki: nie) */
- (NSString *)thumbPath;
- (NSString *)fullPath;
@end
