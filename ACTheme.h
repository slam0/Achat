#import <UIKit/UIKit.h>

/* Wygląd w stylu iOS 6: klasyczny szary iPhone (domyślny), szczotkowany metal (aluminium, mosiądz,
   różowe złoto), ciemne motywy z połyskiem oraz stonowane szkło Frutiger Aero. */

extern NSString *const ACAppearanceDidChangeNotification;   /* zmiana motywu */

/* ---- paleta bieżącego motywu ---- */
typedef struct {
    int accent[3], accentGelT[3], accentGelB[3], accentGelBorder[3];
    int bg[3], bgHi[3], bgLo[3];
    int barT1[3], barT2[3], barB1[3], barB2[3], barTint[3];
    int cellT1[3], cellT2[3], cellB1[3], cellB2[3];
    int selT1[3], selT2[3], selB1[3], selB2[3];
    int text[3], subtle[3], tabOff[3], tabOn[3];
    int hdrT[3], hdrB[3], hdrTitle[3], hdrRight[3];
    int fieldT[3], fieldB[3], fieldText[3];
    int panelT[3], panelB[3];
    int sep[3], neutT[3], neutB[3], neutBorder[3];
    int shadow[3], chrome[3], danger[3];
    int plateT[3], plateM[3], plateB[3];
    int chromeText[3];
    int skyT[3], skyM[3], skyB[3], hillT[3], hillB[3];   /* tło Aero: niebo i wzgórza */
    int tint[3];                                         /* przebarwienie metalu (mosiądz, złoto) */
    float tintAmt;
    float shadowAlpha, shadowDY, cellHiAlpha, cellLoAlpha, texAmp;
    int light;
    int metal;                                  /* 1 = szczotkowany metal */
    int aero;                                   /* 1 = szkło Aero z niebem */
    int classic;                                /* 1 = klasyczny szary iPhone (iOS 6) */
} ACPalette;

const ACPalette *ACP(void);
UIColor *ACRGB(const int *rgb, CGFloat alpha);

/* ---- motywy ---- */
NSInteger ACThemeCount(void);
NSInteger ACCurrentTheme(void);
void ACSetTheme(NSInteger index);               /* zapisuje i ogłasza ACAppearanceDidChangeNotification */
NSString *ACThemeName(NSInteger index);
NSString *ACThemeKind(NSInteger index);         /* krótki opis: "metal", "szkło", "grafit" */
UIImage *ACThemeSwatch(NSInteger index);        /* mała błyszcząca próbka */
UIActivityIndicatorViewStyle ACSpinnerStyle(void);
UIColor *ACGlyphColor(void);

UIColor *ACBackgroundColor(void);       /* kolor tła zwykłych tabel (metal, grafit) */
UIView *ACBackgroundView(CGRect frame); /* widok tła: dla Aero niebo z bąblami, dla reszty tekstura */
UIColor *ACTextColor(void);
UIColor *ACSubtleColor(void);
UIColor *ACAccentColor(void);
void ACStyleShadow(UILabel *label);

void ACStyleNavigationBar(UINavigationBar *bar);
void ACStyleTabBar(UITabBar *bar);
void ACStyleTabItem(UITabBarItem *item, int kind);   /* 0 czaty, 1 kontakty, 2 ustawienia */
UIImage *ACTabIcon(int kind);
void ACStyleTable(UITableView *table);

/* styl: 0 kolor motywu, 1 neutralny, 2 czerwony, 3 zielony */
UIImage *ACGelImage(int style);
UIButton *ACGelButton(NSString *title, int style, CGRect frame);
UIBarButtonItem *ACBarButton(NSString *title, id target, SEL action);

/* ---- elementy rozmowy ---- */
UIImage *ACAvatarImage(NSString *name, CGFloat diameter);   /* szklana kula z inicjałami */
UIImage *ACBubbleImage(BOOL outgoing);                      /* dymek wiadomości (rozciągliwy) */
UIImage *ACBadgeImage(void);                                /* czerwona pastylka licznika (rozciągliwa) */
UIImage *ACInputFieldImage(void);                           /* wpuszczone pole tekstowe (rozciągliwe) */
UIImage *ACInputBarImage(void);                             /* tło paska pisania (rozciągliwe) */
UIImage *ACSearchFieldImage(void);                          /* pole wyszukiwania (rozciągliwe) */
UISearchBar *ACMakeSearchBar(id<UISearchBarDelegate> delegate, NSString *placeholder);
UIColor *ACBubbleTextColor(BOOL outgoing);
