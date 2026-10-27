#import "ACDemo.h"
#import "ACTelegram.h"

@implementation ACMessage
@end

BOOL ACTextMatches(NSString *text, NSString *query)
{
    if (![query length]) return YES;
    if (![text length]) return NO;
    return [text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound;
}

@implementation ACChat

- (BOOL)matchesQuery:(NSString *)query snippet:(NSString **)snippet
{
    if (![query length]) { if (snippet) *snippet = self.preview; return YES; }
    if (ACTextMatches(_name, query) || ACTextMatches(_status, query)) {
        if (snippet) *snippet = self.preview;
        return YES;
    }
    for (NSInteger i = (NSInteger)[_messages count] - 1; i >= 0; i--) {
        ACMessage *m = [_messages objectAtIndex:(NSUInteger)i];
        if (ACTextMatches(m.text, query)) {
            if (snippet) *snippet = m.outgoing ? [@"Ty: " stringByAppendingString:m.text] : m.text;
            return YES;
        }
    }
    return NO;
}

- (id)init
{
    if ((self = [super init])) _messages = [NSMutableArray array];
    return self;
}

- (NSString *)preview
{
    ACMessage *m = [_messages lastObject];
    if (!m) return @"Brak wiadomości";
    return m.outgoing ? [@"Ty: " stringByAppendingString:m.text] : m.text;
}

- (NSString *)lastTime
{
    ACMessage *m = [_messages lastObject];
    return m ? m.time : @"";
}

- (void)addMessage:(NSString *)text outgoing:(BOOL)outgoing
{
    ACMessage *m = [[ACMessage alloc] init];
    m.text = text;
    m.outgoing = outgoing;
    m.time = [ACDemo nowString];
    [_messages addObject:m];
}

@end

static ACChat *Make(NSString *name, NSString *status, NSInteger unread, NSArray *lines)
{
    /* lines: kolejno godzina, kierunek ("<" przychodząca, ">" wychodząca) i tekst, wszystko w jednym napisie "21:05|<|Cześć" */
    ACChat *c = [[ACChat alloc] init];
    c.name = name;
    c.status = status;
    c.unread = unread;
    for (NSString *l in lines) {
        NSArray *p = [l componentsSeparatedByString:@"|"];
        if ([p count] < 3) continue;
        ACMessage *m = [[ACMessage alloc] init];
        m.time = [p objectAtIndex:0];
        m.outgoing = [[p objectAtIndex:1] isEqualToString:@">"];
        m.text = [p objectAtIndex:2];
        [c.messages addObject:m];
    }
    return c;
}

@implementation ACDemo

+ (NSMutableArray *)chats
{
    ACTelegram *t = [ACTelegram shared];
    return t.live ? t.chats : [self demoChats];
}

+ (NSMutableArray *)demoChats
{
    static NSMutableArray *all;
    if (all) return all;
    all = [NSMutableArray array];
    [all addObject:Make(@"Mama", @"online", 2, [NSArray arrayWithObjects:
        @"18:40|<|Kupić coś po drodze?",
        @"18:42|>|Chleb i mleko, jak możesz",
        @"18:44|<|Dobrze. Wrócisz na kolację?",
        @"18:45|<|Zrobię naleśniki 🙂", nil])];
    [all addObject:Make(@"Kuba Nowak", @"był(a) 10 minut temu", 0, [NSArray arrayWithObjects:
        @"17:02|<|Widziałeś ten nowy telefon z Androidem 17?",
        @"17:05|>|Ja tam wolę mojego starego iPhone'a z iOS 6",
        @"17:06|<|Przecież to muzeum 😄",
        @"17:07|>|Muzeum, które działa i wygląda lepiej", nil])];
    [all addObject:Make(@"Klasa 3B", @"24 uczestników", 7, [NSArray arrayWithObjects:
        @"16:20|<|Jutro sprawdzian z matmy czy nie?",
        @"16:23|<|Chyba przełożony na piątek",
        @"16:31|<|Ktoś ma zadania z wczoraj?", nil])];
    [all addObject:Make(@"Ola Kowalska", @"online", 0, [NSArray arrayWithObjects:
        @"15:10|>|Dzięki za zdjęcia!",
        @"15:12|<|Nie ma za co, pokazałam ci jeszcze to z jeziora",
        @"15:12|<|To moje ulubione", nil])];
    [all addObject:Make(@"Tata", @"był(a) wczoraj", 0, [NSArray arrayWithObjects:
        @"wczoraj|<|Pamiętaj o przeglądzie auta",
        @"wczoraj|>|Dobra, umówię się w tym tygodniu", nil])];
    [all addObject:Make(@"Piotrek", @"był(a) 2 godz. temu", 1, [NSArray arrayWithObjects:
        @"14:50|<|Gramy dziś wieczorem?",
        @"14:55|<|Mam nowy serwer", nil])];
    [all addObject:Make(@"Basia", @"online", 0, [NSArray arrayWithObjects:
        @"13:05|<|Wyglądasz na tej tapecie jak z 2009 😍",
        @"13:07|>|To właśnie Frutiger Aero, mała" , nil])];
    [all addObject:Make(@"Wujek Marek", @"był(a) w poniedziałek", 0, [NSArray arrayWithObjects:
        @"pon.|<|Wszystkiego najlepszego!",
        @"pon.|>|Dziękuję, wujku!", nil])];
    [all addObject:Make(@"Kasia z pracy", @"był(a) 3 dni temu", 0, [NSArray arrayWithObjects:
        @"pt.|<|Plik wysłałam mailem",
        @"pt.|>|Mam, dzięki", nil])];
    [all addObject:Make(@"Dominik", @"online", 0, [NSArray arrayWithObjects:
        @"12:30|>|Zadzwonię później",
        @"12:31|<|Ok", nil])];
    return all;
}

+ (NSString *)nowString
{
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    [f setDateFormat:@"HH:mm"];
    return [f stringFromDate:[NSDate date]];
}

+ (NSString *)autoReplyFor:(ACChat *)chat
{
    static NSUInteger n = 0;
    NSArray *r = [NSArray arrayWithObjects:
        @"To tylko odpowiedź demonstracyjna. AeroChat nie jest jeszcze połączony z Telegramem.",
        @"Ładny ten dymek, prawda? 🙂",
        @"Spróbuj zmienić motyw w Ustawieniach: Aluminium wygląda świetnie.",
        @"Hej! Tu wersja pokazowa interfejsu.", nil];
    if (n >= [r count]) n = 0;
    return [r objectAtIndex:n++];
}

@end
