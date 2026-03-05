#import <Carousel.h>
#import <Comment.h>
#import <Post.h>
#import <ToggleImageTableViewCell.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "Preferences.h"

// Forward declaration for FeedFilterSettingsViewController
@interface FeedFilterSettingsViewController : UIViewController
@end

@interface CUICatalog : NSObject {
  NSBundle *_bundle;
}
- (NSArray<NSString *> *)allImageNames;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
@end

static NSMutableArray<NSBundle *> *assetBundles;
static NSMutableArray<CUICatalog *> *assetCatalogs;

extern "C" UIImage *iconWithName(NSString *iconName) {
  for (CUICatalog *catalog in assetCatalogs)
    for (NSString *imageName in [catalog allImageNames])
      if ([imageName hasPrefix:iconName] &&
          (imageName.length == iconName.length || imageName.length == iconName.length + 3))
        return [UIImage imageNamed:imageName
                                 inBundle:object_getIvar(catalog,
                                                         class_getInstanceVariable(
                                                             object_getClass(catalog), "_bundle"))
            compatibleWithTraitCollection:nil];
  return nil;
}

extern "C" NSString *localizedString(NSString *key, NSString *table) {
  for (NSBundle *bundle in assetBundles) {
    NSString *localizedString = [bundle localizedStringForKey:key value:nil table:table];
    if (![localizedString isEqualToString:key]) return localizedString;
  }
  return nil;
}

extern "C" Class CoreClass(NSString *name) {
  Class cls = NSClassFromString(name);
  NSArray *prefixes = @[
    @"Reddit.",
    @"RedditCore.",
    @"RedditCoreModels.",
    @"RedditCore_RedditCoreModels.",
    @"RedditUI.",
  ];
  for (NSString *prefix in prefixes) {
    if (cls) break;
    cls = NSClassFromString([prefix stringByAppendingString:name]);
  }
  return cls;
}

static BOOL shouldFilterObject(id object) {
  NSString *className = NSStringFromClass(object_getClass(object));
  BOOL isAdPost = [className hasSuffix:@"AdPost"] ||
                  ([object respondsToSelector:@selector(isAdPost)] && ((Post *)object).isAdPost) ||
                  ([object respondsToSelector:@selector(isPromotedUserPostAd)] &&
                   [(Post *)object isPromotedUserPostAd]) ||
                  ([object respondsToSelector:@selector(isPromotedCommunityPostAd)] &&
                   [(Post *)object isPromotedCommunityPostAd]);
  BOOL isRecommendation = [className containsString:@"Recommend"];
  BOOL isNSFW = [object respondsToSelector:@selector(isNSFW)] && ((Post *)object).isNSFW;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] && isAdPost)
    return YES;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended] && isRecommendation)
    return YES;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterNSFW] && isNSFW) return YES;
  return NO;
}

static NSArray *filteredObjects(NSArray *objects) {
  return [objects filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                               id object, NSDictionary *bindings) {
                    return !shouldFilterObject(object);
                  }]];
}

static void filterNode(NSMutableDictionary *node) {
  if (![node isKindOfClass:NSMutableDictionary.class]) return;
  if ([node[@"__typename"] isEqualToString:@"SubredditPost"]) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards]) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores])
      node[@"isScoreHidden"] = @YES;
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterNSFW] &&
        [node[@"isNsfw"] boolValue])
      node[@"isHidden"] = @YES;
  }
  if ([node[@"__typename"] isEqualToString:@"CellGroup"]) {
    for (NSMutableDictionary *cell in node[@"cells"]) {
      if ([cell[@"__typename"] isEqualToString:@"ActionCell"]) {
        if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards]) {
          cell[@"isAwardHidden"] = @YES;
          id goldenUpvoteInfo = cell[@"goldenUpvoteInfo"];
          if ([goldenUpvoteInfo isKindOfClass:NSDictionary.class] &&
              ![goldenUpvoteInfo isEqual:[NSNull null]]) {
            cell[@"goldenUpvoteInfo"][@"isGildable"] = @NO;
          }
        }
        if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores])
          cell[@"isScoreHidden"] = @YES;
      }
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] &&
        [node[@"adPayload"] isKindOfClass:NSDictionary.class]) {
      node[@"cells"] = @[];
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended] &&
        ![node[@"recommendationContext"] isEqual:[NSNull null]] &&
        [node[@"recommendationContext"] isKindOfClass:NSDictionary.class]) {
      NSDictionary *recommendationContext = node[@"recommendationContext"];
      id typeName = recommendationContext[@"typeName"];
      id typeIdentifier = recommendationContext[@"typeIdentifier"];
      id isContextHidden = recommendationContext[@"isContextHidden"];
      if (![typeIdentifier isEqual:[NSNull null]] && ![typeName isEqual:[NSNull null]] &&
          ![isContextHidden isEqual:[NSNull null]] &&
          [typeIdentifier isKindOfClass:NSString.class] &&
          [typeName isKindOfClass:NSString.class] &&
          [isContextHidden isKindOfClass:NSNumber.class]) {
        if (!(([typeName isEqualToString:@"PopularRecommendationContext"] ||
               [typeIdentifier hasPrefix:@"global_popular"]) &&
              [isContextHidden boolValue])) {
          node[@"cells"] = @[];
        }
      }
    }
  }
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted]) {
    if ([node[@"__typename"] isEqualToString:@"AdPost"]) {
      node[@"isHidden"] = @YES;
    }
  }
  if ([node[@"__typename"] isEqualToString:@"Comment"]) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards]) {
      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores])
      node[@"isScoreHidden"] = @YES;
    if ([node[@"authorInfo"] isKindOfClass:NSDictionary.class] &&
        [node[@"authorInfo"][@"id"] isEqualToString:@"t2_6l4z3"] &&
        [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAutoCollapseAutoMod])
      node[@"isInitiallyCollapsed"] = @YES;
  }
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response,
                                                        NSError *error))completionHandler {
  if (![request.URL.host hasPrefix:@"gql"] && ![request.URL.host hasPrefix:@"oauth"])
    return %orig;
  void (^newCompletionHandler)(NSData *, NSURLResponse *, NSError *) =
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return completionHandler(data, response, error);
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:NSJSONReadingMutableContainers
                                                               error:&error];
        if (error || !json) return completionHandler(data, response, error);
        if ([json isKindOfClass:NSDictionary.class]) {
          if (json[@"data"] && [json[@"data"] isKindOfClass:NSDictionary.class]) {
            NSDictionary *data = json[@"data"];
            NSMutableDictionary *root = data.allValues.firstObject;
            if ([root isKindOfClass:NSDictionary.class]) {
              if ([root.allValues.firstObject isKindOfClass:NSDictionary.class] &&
                  root.allValues.firstObject[@"edges"])
                for (NSMutableDictionary *edge in root.allValues.firstObject[@"edges"])
                  filterNode(edge[@"node"]);
              if (root[@"commentForest"])
                for (NSMutableDictionary *tree in root[@"commentForest"][@"trees"])
                  filterNode(tree[@"node"]);
              if (root[@"commentsPageAds"] &&
                  [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted])
                root[@"commentsPageAds"] = @[];
              if (root[@"commentTreeAds"] &&
                  [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted])
                root[@"commentTreeAds"] = @[];
              if (root[@"pdpCommentsAds"] &&
                  [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted])
                root[@"pdpCommentsAds"] = @[];
              if (root[@"recommendations"] &&
                  [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended])
                root[@"recommendations"] = @[];
            } else if ([root isKindOfClass:NSArray.class]) {
              for (NSMutableDictionary *node in (NSArray *)root) filterNode(node);
            }
          }
        }
        data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        completionHandler(data, response, error);
      };
  return %orig(request, newCompletionHandler);
}
%end

// ============================================================================
// MARK: - HELPER: present RedditFilter settings
// ============================================================================

static void redditFilter_presentSettings(UIViewController *fromVC) {
    Class filterVCClass = NSClassFromString(@"FeedFilterSettingsViewController");
    if (!filterVCClass) {
        NSLog(@"[RedditFilter] ERROR: FeedFilterSettingsViewController class not found");
        return;
    }
    UIViewController *filterVC = [[filterVCClass alloc] init];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:filterVC];

    // If the drawer/sheet is currently presented, dismiss it first then show settings
    if (fromVC.presentedViewController) {
        [fromVC dismissViewControllerAnimated:YES completion:^{
            [fromVC presentViewController:nav animated:YES completion:nil];
        }];
    } else {
        [fromVC presentViewController:nav animated:YES completion:nil];
    }
}

// ============================================================================
// MARK: - DEBUG: on-screen logger (no jailbreak / no file access needed)
// Shows a UIAlert with the last N log lines whenever a presentation happens.
// Tap "Copy" to copy the log to clipboard, then paste it anywhere.
// ============================================================================

static NSMutableArray<NSString *> *rf_debugLines;

static void rf_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[RedditFilter] %@", msg);

    if (!rf_debugLines) rf_debugLines = [NSMutableArray array];
    NSString *timestamp = [NSDateFormatter
        localizedStringFromDate:[NSDate date]
                      dateStyle:NSDateFormatterNoStyle
                      timeStyle:NSDateFormatterMediumStyle];
    [rf_debugLines addObject:[NSString stringWithFormat:@"[%@] %@", timestamp, msg]];
    // Keep last 60 lines
    while (rf_debugLines.count > 60) [rf_debugLines removeObjectAtIndex:0];
}

static void rf_showDebugLog(void) {
    NSString *logText = [rf_debugLines componentsJoinedByString:@"\n"] ?: @"(no logs yet)";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"RedditFilter Debug Log"
                         message:logText
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Copy to Clipboard"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
                    [UIPasteboard generalPasteboard].string = logText;
                }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Clear & Close"
                  style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *a) {
                    [rf_debugLines removeAllObjects];
                }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Close"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    UIViewController *top = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        if (w.isKeyWindow) { top = w.rootViewController; break; }
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// MARK: - DEBUG: log every presented VC and UIAlertController actions
// ============================================================================

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    rf_log(@"present: %@ from: %@",
           NSStringFromClass(object_getClass(vc)),
           NSStringFromClass(object_getClass(self)));

    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        rf_log(@"  AlertController style=%ld title='%@'",
               (long)alert.preferredStyle, alert.title);
        for (UIAlertAction *a in alert.actions)
            rf_log(@"    action:'%@' style=%ld", a.title, (long)a.style);
    }
    %orig;
}

%end

// ============================================================================
// MARK: - HELPER: find the top-most presentable VC
// ============================================================================

static UIViewController *rf_topPresentableVC(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        if (w.isKeyWindow) { keyWindow = w; break; }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = [(UINavigationController *)vc topViewController];
    return vc;
}

// ============================================================================
// MARK: - 3-FINGER LONG PRESS (always available as fallback)
// ============================================================================

%hook UIWindow

- (void)becomeKeyWindow {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Long press (1s) with 3 fingers → open RedditFilter settings
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(redditFilter_handleThreeFingerLongPress:)];
        longPress.numberOfTouchesRequired = 3;
        longPress.minimumPressDuration    = 1.0;
        [self addGestureRecognizer:longPress];

        // Short press (0.1s) with 3 fingers → show debug log
        UILongPressGestureRecognizer *shortPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(redditFilter_handleThreeFingerShortPress:)];
        shortPress.numberOfTouchesRequired = 3;
        shortPress.minimumPressDuration    = 0.1;
        [self addGestureRecognizer:shortPress];

        NSLog(@"[RedditFilter] 3-finger gestures installed");
    });
}

%new
- (void)redditFilter_handleThreeFingerLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    rf_log(@"3-finger long press → opening settings");
    redditFilter_presentSettings(rf_topPresentableVC());
}

%new
- (void)redditFilter_handleThreeFingerShortPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    rf_log(@"3-finger short press → showing debug log");
    rf_showDebugLog();
}

%end

// ============================================================================
// MARK: - INJECT "RedditFilter Settings" INTO RPLBottomSheet
//
// Reddit uses RPLBottomSheetPanModalWrapperViewController (from RedditSliceKit)
// instead of UIAlertController for its action menus.
// We hook -[UIViewController viewDidAppear:] on that specific class and inject
// a button into its view hierarchy, OR we hook the table/collection view
// inside it to add an extra row — using the same approach as before but now
// correctly targeted at the right VC class.
//
// Strategy: hook viewWillAppear: on any VC whose class name contains
// "BottomSheet" presented from a "Profile" VC, find the UITableView or
// UICollectionView inside it, and inject our row via the data source.
// ============================================================================

// Associated-object key: marks data sources we have already patched
static const void *kRFDataSourcePatchedKey = &kRFDataSourcePatchedKey;

static BOOL rf_isBottomSheetFromProfileVC(UIViewController *vc) {
    NSString *n = NSStringFromClass(object_getClass(vc));
    if (![n containsString:@"BottomSheet"]) return NO;
    // Check the presenter chain for a Profile VC
    UIViewController *cursor = vc.presentingViewController;
    while (cursor) {
        NSString *cn = NSStringFromClass(object_getClass(cursor));
        if ([cn containsString:@"Profile"]  ||
            [cn containsString:@"Drawer"]   ||
            [cn containsString:@"Account"]  ||
            [cn containsString:@"UserMenu"]) return YES;
        cursor = cursor.presentingViewController ?: cursor.parentViewController;
    }
    return NO;
}

// Recursively find the first UITableView in a view hierarchy
static UITableView *rf_findTableView(UIView *root) {
    if ([root isKindOfClass:[UITableView class]]) return (UITableView *)root;
    for (UIView *sub in root.subviews) {
        UITableView *tv = rf_findTableView(sub);
        if (tv) return tv;
    }
    return nil;
}

// Associated-object keys for our injected data source wrapper
static const void *kRFInjectedDataSourceKey = &kRFInjectedDataSourceKey;

// ── Lightweight Objective-C wrapper that adds one extra row ──────────────────
@interface RFTableViewDataSourceWrapper : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) id<UITableViewDataSource> originalDataSource;
@property (nonatomic, weak) id<UITableViewDelegate>   originalDelegate;
@property (nonatomic, weak) UIViewController          *presentingVC;
@end

@implementation RFTableViewDataSourceWrapper

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    if ([self.originalDataSource respondsToSelector:@selector(numberOfSectionsInTableView:)])
        return [self.originalDataSource numberOfSectionsInTableView:tv];
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    NSInteger orig = [self.originalDataSource tableView:tv numberOfRowsInSection:section];
    // Add our row only in the last section
    NSInteger sections = [self numberOfSectionsInTableView:tv];
    if (section == sections - 1) return orig + 1;
    return orig;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSInteger sections = [self numberOfSectionsInTableView:tv];
    NSInteger origRows = [self.originalDataSource tableView:tv
                                     numberOfRowsInSection:ip.section];
    // Our injected row is the last row of the last section
    if (ip.section == sections - 1 && ip.row == origRows) {
        static NSString *cellID = @"RFSettingsCell";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:cellID];
        cell.textLabel.text = @"RedditFilter Settings";
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        if (@available(iOS 13.0, *))
            cell.imageView.image = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    return [self.originalDataSource tableView:tv cellForRowAtIndexPath:ip];
}

// Forward all other data source methods
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    if ([self.originalDataSource respondsToSelector:@selector(tableView:canEditRowAtIndexPath:)])
        return [self.originalDataSource tableView:tv canEditRowAtIndexPath:ip];
    return NO;
}

// Forward delegate methods
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSInteger sections = [self numberOfSectionsInTableView:tv];
    NSInteger origRows = [self.originalDataSource tableView:tv
                                     numberOfRowsInSection:ip.section];
    if (ip.section == sections - 1 && ip.row == origRows) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        rf_log(@"RedditFilter Settings tapped in BottomSheet");
        redditFilter_presentSettings(rf_topPresentableVC());
        return;
    }
    if ([self.originalDelegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)])
        [self.originalDelegate tableView:tv didSelectRowAtIndexPath:ip];
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    NSInteger sections = [self numberOfSectionsInTableView:tv];
    NSInteger origRows = [self.originalDataSource tableView:tv
                                     numberOfRowsInSection:ip.section];
    if (ip.section == sections - 1 && ip.row == origRows) return 50.0;
    if ([self.originalDelegate respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)])
        return [self.originalDelegate tableView:tv heightForRowAtIndexPath:ip];
    return UITableViewAutomaticDimension;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    if ([self.originalDelegate respondsToSelector:@selector(tableView:viewForHeaderInSection:)])
        return [self.originalDelegate tableView:tv viewForHeaderInSection:section];
    return nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    if ([self.originalDelegate respondsToSelector:@selector(tableView:heightForHeaderInSection:)])
        return [self.originalDelegate tableView:tv heightForHeaderInSection:section];
    return UITableViewAutomaticDimension;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    if ([self.originalDelegate respondsToSelector:@selector(tableView:viewForFooterInSection:)])
        return [self.originalDelegate tableView:tv viewForFooterInSection:section];
    return nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section {
    if ([self.originalDelegate respondsToSelector:@selector(tableView:heightForFooterInSection:)])
        return [self.originalDelegate tableView:tv heightForFooterInSection:section];
    return UITableViewAutomaticDimension;
}

@end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!rf_isBottomSheetFromProfileVC(self)) return;
    rf_log(@"BottomSheet appeared: %@", NSStringFromClass(object_getClass(self)));

    // Already injected?
    if (objc_getAssociatedObject(self, kRFInjectedDataSourceKey)) return;

    // Log all child VCs to understand the hierarchy
    rf_log(@"  childVCs count: %lu", (unsigned long)self.childViewControllers.count);
    for (UIViewController *child in self.childViewControllers)
        rf_log(@"  childVC: %@", NSStringFromClass(object_getClass(child)));

    // Search table view in self.view recursively (already done), then also
    // search inside every child VC's view
    UITableView *tv = rf_findTableView(self.view);

    if (!tv) {
        for (UIViewController *child in self.childViewControllers) {
            rf_log(@"  searching in childVC: %@", NSStringFromClass(object_getClass(child)));
            tv = rf_findTableView(child.view);
            if (tv) { rf_log(@"  found UITableView in child!"); break; }

            // If child is a nav controller, check its topViewController
            if ([child isKindOfClass:[UINavigationController class]]) {
                UIViewController *top = [(UINavigationController *)child topViewController];
                rf_log(@"  NavController topVC: %@", NSStringFromClass(object_getClass(top)));
                tv = rf_findTableView(top.view);
                if (tv) { rf_log(@"  found UITableView in navController topVC!"); break; }

                // Also log its subviews
                for (UIView *v in top.view.subviews)
                    rf_log(@"    topVC subview: %@", NSStringFromClass(object_getClass(v)));
            }
        }
    }

    if (!tv) {
        rf_log(@"  No UITableView found anywhere — logging all subviews recursively:");
        NSMutableArray *queue = [NSMutableArray arrayWithObject:self.view];
        while (queue.count) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            rf_log(@"    view: %@ frame:%@", NSStringFromClass(object_getClass(v)),
                   NSStringFromCGRect(v.frame));
            [queue addObjectsFromArray:v.subviews];
        }
        return;
    }

    rf_log(@"  Found UITableView, injecting data source wrapper");

    RFTableViewDataSourceWrapper *wrapper = [[RFTableViewDataSourceWrapper alloc] init];
    wrapper.originalDataSource = tv.dataSource;
    wrapper.originalDelegate   = tv.delegate;
    wrapper.presentingVC       = self;

    // Retain wrapper via associated object on the VC
    objc_setAssociatedObject(self, kRFInjectedDataSourceKey, wrapper,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    tv.dataSource = wrapper;
    tv.delegate   = wrapper;
    [tv reloadData];
}

%end

// ============================================================================
// MARK: - LEGACY HOOKS
// ============================================================================

%group Legacy

%hook Listing
- (void)fetchNextPage:(id (^)(NSArray *, id))completionHandler {
  id (^newCompletionHandler)(NSArray *, id) = ^(NSArray *objects, id _) {
    return completionHandler(filteredObjects(objects), _);
  };
  return %orig(newCompletionHandler);
}
%end

%hook FeedNetworkSource
- (NSArray *)postsAndCommentsFromData:(id)data {
  return filteredObjects(%orig);
}
%end

%hook PostDetailPresenter
- (BOOL)shouldFetchCommentAdPost {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] ? NO : %orig;
}
- (BOOL)shouldFetchAdditionalCommentAdPosts {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] ? NO : %orig;
}
%end

%hook Carousel
- (BOOL)isHiddenByUserWithAccountSettings:(id)accountSettings {
  return ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended] &&
          ([self.analyticType containsString:@"recommended"] ||
           [self.analyticType containsString:@"similar"] ||
           [self.analyticType containsString:@"popular"])) ||
         %orig;
}
%end

%hook QuickActionViewModel
- (void)fetchActions {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended]) return;
  %orig;
}
%end

%hook Post
- (NSArray *)awardingTotals {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? 0 : %orig;
}
- (BOOL)canAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores] ? YES : %orig;
}
%end

%hook Comment
- (NSArray *)awardingTotals {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? 0 : %orig;
}
- (BOOL)canAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO : %orig;
}
- (BOOL)shouldHighlightForHighAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterScores] ? YES : %orig;
}
- (BOOL)shouldAutoCollapse {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAutoCollapseAutoMod] &&
                 [((Comment *)self).authorPk isEqualToString:@"t2_6l4z3"]
             ? YES : %orig;
}
%end

%hook ToggleImageTableViewCell
- (void)updateConstraints {
  %orig;
  UIStackView *horizontalStackView =
      [self respondsToSelector:@selector(imageLabelView)]
          ? [self imageLabelView].horizontalStackView
          : object_getIvar(self,
                           class_getInstanceVariable(object_getClass(self), "horizontalStackView"));
  UILabel *detailLabel = [self respondsToSelector:@selector(imageLabelView)]
                             ? [self imageLabelView].detailLabel
                             : [self detailLabel];
  if (!horizontalStackView || !detailLabel) return;
  if (detailLabel.text) {
    UIView *contentView = [self contentView];
    [contentView addConstraints:@[
      [NSLayoutConstraint constraintWithItem:detailLabel
                                   attribute:NSLayoutAttributeHeight
                                   relatedBy:NSLayoutRelationEqual
                                      toItem:horizontalStackView
                                   attribute:NSLayoutAttributeHeight
                                  multiplier:.33
                                    constant:0],
      [NSLayoutConstraint constraintWithItem:horizontalStackView
                                   attribute:NSLayoutAttributeHeight
                                   relatedBy:NSLayoutRelationEqual
                                      toItem:contentView
                                   attribute:NSLayoutAttributeHeight
                                  multiplier:1
                                    constant:0],
      [NSLayoutConstraint constraintWithItem:horizontalStackView
                                   attribute:NSLayoutAttributeCenterY
                                   relatedBy:NSLayoutRelationEqual
                                      toItem:contentView
                                   attribute:NSLayoutAttributeCenterY
                                  multiplier:1
                                    constant:0]
    ]];
  }
}
%end

%end

%ctor {
  NSLog(@"[RedditFilter] Initializing - injecting entry into profile drawer menu");

  assetBundles = [NSMutableArray array];
  assetCatalogs = [NSMutableArray array];
  [assetBundles addObject:NSBundle.mainBundle];
  for (NSString *file in
       [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSBundle.mainBundle.bundlePath
                                                         error:nil]) {
    if (![file hasSuffix:@"bundle"]) continue;
    NSBundle *bundle = [NSBundle
        bundleWithPath:[NSBundle.mainBundle pathForResource:[file stringByDeletingPathExtension]
                                                     ofType:@"bundle"]];
    if (bundle) [assetBundles addObject:bundle];
  }
  for (NSString *file in [NSFileManager.defaultManager
           contentsOfDirectoryAtPath:[NSBundle.mainBundle.bundlePath
                                         stringByAppendingPathComponent:@"Frameworks"]
                               error:nil]) {
    if (![file hasSuffix:@"framework"]) continue;
    NSString *frameworkPath =
        [NSBundle.mainBundle pathForResource:[file stringByDeletingPathExtension]
                                      ofType:@"framework"
                                 inDirectory:@"Frameworks"];
    NSBundle *bundle = [NSBundle bundleWithPath:frameworkPath];
    if (bundle) [assetBundles addObject:bundle];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworkPath
                                                                             error:nil]) {
      if (![file hasSuffix:@"bundle"]) continue;
      NSBundle *bundle =
          [NSBundle bundleWithPath:[frameworkPath stringByAppendingPathComponent:file]];
      if (bundle) [assetBundles addObject:bundle];
    }
  }
  for (NSBundle *bundle in assetBundles) {
    NSError *error;
    CUICatalog *catalog = [[%c(CUICatalog) alloc] initWithName:@"Assets"
                                                               fromBundle:bundle
                                                                    error:&error];
    if (!error) [assetCatalogs addObject:catalog];
  }

  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if (![defaults objectForKey:kRedditFilterPromoted])
    [defaults setBool:true forKey:kRedditFilterPromoted];
  if (![defaults objectForKey:kRedditFilterRecommended])
    [defaults setBool:false forKey:kRedditFilterRecommended];
  if (![defaults objectForKey:kRedditFilterNSFW])
    [defaults setBool:false forKey:kRedditFilterNSFW];
  if (![defaults objectForKey:kRedditFilterAwards])
    [defaults setBool:false forKey:kRedditFilterAwards];
  if (![defaults objectForKey:kRedditFilterScores])
    [defaults setBool:false forKey:kRedditFilterScores];
  if (![defaults objectForKey:kRedditFilterAutoCollapseAutoMod])
    [defaults setBool:false forKey:kRedditFilterAutoCollapseAutoMod];

  NSLog(@"[RedditFilter] Loaded - open the profile drawer to find 'RedditFilter Settings'");

  %init;
  %init(Legacy, Comment = CoreClass(@"Comment"), Post = CoreClass(@"Post"),
                   QuickActionViewModel = CoreClass(@"QuickActionViewModel"),
                   ToggleImageTableViewCell = CoreClass(@"ToggleImageTableViewCell"));
}
