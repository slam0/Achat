#import "ACCrash.h"

static NSString *DocPath(NSString *name)
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[dirs objectAtIndex:0] stringByAppendingPathComponent:name];
}

static void WriteText(NSString *text, NSString *name)
{
    [text writeToFile:DocPath(name) atomically:NO encoding:NSUTF8StringEncoding error:NULL];
}

static void ACExceptionHandler(NSException *e)
{
    NSString *stack = @"";
    if ([e respondsToSelector:@selector(callStackSymbols)]) stack = [[e callStackSymbols] componentsJoinedByString:@"\n"];
    NSString *text = [NSString stringWithFormat:@"%@\n%@\n%@", [e name], [e reason], stack];
    WriteText(text, @"blad.txt");
}

void ACCrashInstall(void)
{
    NSSetUncaughtExceptionHandler(&ACExceptionHandler);
}

void ACCrumb(NSString *step)
{
    WriteText(step, @"ostatni-krok.txt");
}

void ACCrumbCleanExit(void)
{
    WriteText(@"OK", @"ostatni-krok.txt");
}

NSString *ACTakeLastRunReport(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *crumb = [NSString stringWithContentsOfFile:DocPath(@"ostatni-krok.txt") encoding:NSUTF8StringEncoding error:NULL];
    NSString *err = [NSString stringWithContentsOfFile:DocPath(@"blad.txt") encoding:NSUTF8StringEncoding error:NULL];
    [fm removeItemAtPath:DocPath(@"blad.txt") error:NULL];
    NSString *report = nil;
    if ([err length]) {
        if ([err length] > 700) err = [err substringToIndex:700];
        report = [NSString stringWithFormat:@"Błąd: %@\n\nOstatni krok: %@", err, crumb ? crumb : @"?"];
    } else if ([crumb length] && ![crumb isEqualToString:@"OK"]) {
        report = [NSString stringWithFormat:@"Poprzednie uruchomienie nie zakończyło się prawidłowo.\nOstatni krok: %@", crumb];
    }
    return report;
}
