#import "ACSettingsController.h"
#import "ACTheme.h"
#import "ACViews.h"
#import "ACTelegram.h"
#import "ACSetupController.h"

@implementation ACSettingsController

- (id)init
{
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Ustawienia";
    ACStyleTable(self.tableView);
    self.tableView.rowHeight = 52.0f;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(telegramChanged:) name:ACTGStateDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)telegramChanged:(NSNotification *)n { [self.tableView reloadData]; }

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    if (s == 0) return ACThemeCount();
    if (s == 1) return [ACTelegram shared].authorized ? 3 : 2;
    return 2;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s
{
    NSArray *t = [NSArray arrayWithObjects:@"Motyw wyglądu", @"Telegram", @"O aplikacji", nil];
    return ACHeaderForTitle([t objectAtIndex:(NSUInteger)s]);
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 26.0f; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    ACCell *cell = [ACCell cellForTable:tv identifier:[NSString stringWithFormat:@"s%ld", (long)ip.section]];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    if (ip.section == 0) {
        cell.imageView.image = ACThemeSwatch(ip.row);
        cell.textLabel.text = ACThemeName(ip.row);
        cell.detailTextLabel.text = ACThemeKind(ip.row);
        cell.accessoryType = (ip.row == ACCurrentTheme()) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else if (ip.section == 1) {
        ACTelegram *tg = [ACTelegram shared];
        if (ip.row == 0) {
            if (tg.authorized) {
                cell.textLabel.text = [NSString stringWithFormat:@"Zalogowano: %@", [tg.userName length] ? tg.userName : @"konto Telegram"];
                cell.detailTextLabel.text = tg.online ? @"Połączono z Telegramem" : @"Łączenie…";
            } else {
                cell.textLabel.text = @"Zaloguj się do Telegrama";
                cell.detailTextLabel.text = @"Numer telefonu i kod z SMS-a";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
        } else if (ip.row == 1) {
            cell.textLabel.text = tg.authorized ? @"Odśwież czaty" : @"Tryb demo";
            cell.detailTextLabel.text = tg.authorized ? @"Pobierz listę rozmów jeszcze raz" : @"Na liście są przykładowe rozmowy, nic nie jest wysyłane";
            cell.selectionStyle = tg.authorized ? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"Wyloguj";
            cell.detailTextLabel.text = @"Usuwa sesję z tego telefonu";
        }
    } else if (ip.row == 0) {
        cell.textLabel.text = @"AeroChat 0.7.2";
        cell.detailTextLabel.text = @"Klient Telegrama: czaty, wysyłanie, wyszukiwanie, załączniki";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Wygląd";
        cell.detailTextLabel.text = @"Szary iPhone, szczotkowany metal, ciemne motywy i szkło Aero (iOS 6)";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        ACTelegram *tg = [ACTelegram shared];
        if (ip.row == 0 && !tg.authorized) [ACSetupController presentFrom:self.tabBarController ? self.tabBarController : self];
        else if (ip.row == 1 && tg.authorized) [tg reloadDialogs];
        else if (ip.row == 2) {
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Wylogować z Telegrama?" message:@"Sesja zostanie usunięta z tego telefonu." delegate:self cancelButtonTitle:@"Anuluj" otherButtonTitles:@"Wyloguj", nil];
            [a show];
        }
        return;
    }
    if (ip.section != 0) return;
    ACSetTheme(ip.row);      /* AppDelegate odbuduje cały interfejs w nowym motywie */
}

- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)i
{
    if (i == 1) [[ACTelegram shared] logOut];
}

@end
