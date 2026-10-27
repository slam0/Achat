#import <Foundation/Foundation.h>

/* Prosta diagnostyka: aplikacja zapisuje w Documents ostatni "krok" oraz treść nieobsłużonego wyjątku.
   Przy następnym uruchomieniu pokazuje to w okienku, żeby można było zrobić zdjęcie ekranu. */

void ACCrashInstall(void);
void ACCrumb(NSString *step);                 /* zapamiętuje, co aplikacja właśnie robi */
void ACCrumbCleanExit(void);                  /* zwykłe wyjście do tła: zaznacza, że wszystko było w porządku */
NSString *ACTakeLastRunReport(void);          /* tekst o poprzednim, nieudanym uruchomieniu albo nil; czyści pliki */
