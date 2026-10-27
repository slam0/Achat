#import "ACSettingsController.h"
#import "ACTheme.h"
#import "ACViews.h"

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
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    if (s == 0) return ACThemeCount();
    if (s == 1) return 1;
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
        cell.textLabel.text = @"Połączenie z Telegramem";
        cell.detailTextLabel.text = @"Wkrótce: etap 2 (logowanie numerem telefonu)";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.row == 0) {
        cell.textLabel.text = @"AeroChat 0.1.0";
        cell.detailTextLabel.text = @"Wersja z danymi pokazowymi: sam wygląd";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Wygląd";
        cell.detailTextLabel.text = @"Frutiger Aero, szczotkowany metal i grafit z połyskiem (iOS 6)";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0) return;
    ACSetTheme(ip.row);      /* AppDelegate odbuduje cały interfejs w nowym motywie */
}

@end
