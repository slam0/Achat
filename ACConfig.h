#ifndef AC_CONFIG_H
#define AC_CONFIG_H
/* Klucze aplikacji Telegrama (api_id i api_hash z my.telegram.org). Zakłada je JEDEN RAZ autor aplikacji;
   użytkownik aplikacji loguje się potem samym numerem telefonu i nigdy ich nie widzi.
   Klucze trafiają tu z sekretów GitHuba TG_API_ID i TG_API_HASH (workflow tworzy plik ACConfigLocal.h przy budowaniu),
   albo wpisz je ręcznie do ACConfigLocal.h (plik jest w .gitignore, nie wrzucaj go do repozytorium). */
#if __has_include("ACConfigLocal.h")
#include "ACConfigLocal.h"
#endif
#ifndef AC_TG_API_ID
#define AC_TG_API_ID 0
#endif
#ifndef AC_TG_API_HASH
#define AC_TG_API_HASH ""
#endif
#endif
