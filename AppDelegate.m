#import "AppDelegate.h"
#import "ACStore.h"
#import "ACTheme.h"
#import "ACCrash.h"
#import "ACChatsController.h"
#import "ACContactsController.h"
#import "ACSettingsController.h"

@implementation AppDelegate

- (UINavigationController *)navWith:(UIViewController *)root title:(NSString *)title kind:(int)kind
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    ACStyleNavigationBar(nav.navigationBar);
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:ACTabIcon(kind) tag:kind];
    ACStyleTabItem(nav.tabBarItem, kind);
    return nav;
}

/* cały interfejs od zera: przy starcie oraz po zmianie motywu */
- (UITabBarController *)buildTabs
{
    NSArray *controllers = [NSArray arrayWithObjects:
        [self navWith:[[ACChatsController alloc] init] title:@"Czaty" kind:0],
        [self navWith:[[ACContactsController alloc] init] title:@"Kontakty" kind:1],
        [self navWith:[[ACSettingsController alloc] init] title:@"Ustawienia" kind:2], nil];
    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = controllers;
    ACStyleTabBar(tabs.tabBar);
    return tabs;
}

- (void)appearanceChanged:(NSNotification *)n
{
    [self performSelector:@selector(rebuildInterface) withObject:nil afterDelay:0.0];
}

- (void)rebuildInterface
{
    UITabBarController *old = (UITabBarController *)self.window.rootViewController;
    NSUInteger selected = [old isKindOfClass:[UITabBarController class]] ? old.selectedIndex : 0;
    [old dismissViewControllerAnimated:NO completion:nil];
    UITabBarController *tabs = [self buildTabs];
    tabs.selectedIndex = selected;
    [UIView transitionWithView:self.window duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self.window.rootViewController = tabs; } completion:nil];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSString *lastReport = ACTakeLastRunReport();
    ACCrashInstall();
    ACCrumb(@"start aplikacji");
    [ACStore shared];
    [application setStatusBarStyle:UIStatusBarStyleBlackOpaque];
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = [self buildTabs];
    ACCrumb(@"interfejs zbudowany");
    [self.window makeKeyAndVisible];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appearanceChanged:) name:ACAppearanceDidChangeNotification object:nil];

    /* ekran powitalny: ten sam obraz co Default.png, przytrzymany chwilę i płynnie zgaszony */
    CGRect bounds = [[UIScreen mainScreen] bounds];
    UIImage *splash = [UIImage imageNamed:(bounds.size.height > 480.0f ? @"Default-568h" : @"Default")];
    if (splash) {
        UIImageView *cover = [[UIImageView alloc] initWithFrame:bounds];
        cover.image = splash;
        cover.contentMode = UIViewContentModeScaleAspectFill;
        cover.clipsToBounds = YES;
        [self.window addSubview:cover];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.4 animations:^{ cover.alpha = 0.0f; }
                             completion:^(BOOL finished) { [cover removeFromSuperview]; }];
        });
    }
    if (lastReport) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"AeroChat – diagnostyka" message:lastReport delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [a show];
        });
    }
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application { [[ACStore shared] save]; ACCrumbCleanExit(); }
- (void)applicationWillTerminate:(UIApplication *)application { [[ACStore shared] save]; ACCrumbCleanExit(); }

@end
