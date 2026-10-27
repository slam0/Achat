#ifndef TG_TL_H
#define TG_TL_H
/* Silnik TL (język opisu typów Telegrama) sterowany schematem api.tl:
   - odczyt dowolnego obiektu binarnego do tekstu JSON,
   - zapis obiektu (np. wywołania funkcji) z JSON do postaci binarnej.
   Dzięki temu aplikacja nie ma wpisanych "na sztywno" identyfikatorów ani układu pól. */
#include <stdint.h>
#include <stddef.h>

typedef struct tl_schema tl_schema;

tl_schema *tl_schema_load(const char *text, size_t len);
void tl_schema_free(tl_schema *s);
int tl_schema_layer(const tl_schema *s);                  /* z komentarza "// LAYER n"; 0 gdy brak */
int tl_schema_count(const tl_schema *s);

/* Odczyt obiektu z identyfikatorem konstruktora na początku. Zwraca 0 = ok (*json z malloc), inaczej -1 i err. */
int tl_read_json(const tl_schema *s, const uint8_t *data, size_t len, char **json, size_t *used, char *err, int errlen);

/* Odczyt wyniku funkcji o podanej nazwie (np. "users.getUsers", wynik Vector<User>). */
int tl_read_result_json(const tl_schema *s, const char *function, const uint8_t *data, size_t len, char **json, size_t *used, char *err, int errlen);

/* Zapis: json = {"_":"auth.sendCode", ...}. Pola flag liczone automatycznie. Wynik w *out (malloc). */
int tl_write_json(const tl_schema *s, const char *json, uint8_t **out, size_t *outlen, char *err, int errlen);

/* Identyfikator konstruktora po nazwie; 0 gdy nie istnieje. */
uint32_t tl_id_for_name(const tl_schema *s, const char *name);
/* Nazwa konstruktora po identyfikatorze; NULL gdy nie istnieje. */
const char *tl_name_for_id(const tl_schema *s, uint32_t id);

#endif
