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
// Reddit now renders the account menu as a pure SwiftUI view inside
// _TtGC14RedditSliceKit23RedditHostingControllerV29ProfileMyAccountSettings...
// There is no UICollectionView or UITableView to hook anymore.
//
// Strategy: hook viewDidAppear: on any VC whose class name contains
// "BottomSheet" presented from a Profile VC, find the SwiftUI hosting
// controller child, and append a native UIButton at the bottom of its view.
// ============================================================================

static const void *kRFCollectionPatchedKey = &kRFCollectionPatchedKey;

static UICollectionView *rf_findCollectionView(UIView *root) {
    if ([root isKindOfClass:[UICollectionView class]]) return (UICollectionView *)root;
    for (UIView *sub in root.subviews) {
        UICollectionView *cv = rf_findCollectionView(sub);
        if (cv) return cv;
    }
    return nil;
}

static UICollectionView *rf_findCollectionViewInVC(UIViewController *vc) {
    UICollectionView *cv = rf_findCollectionView(vc.view);
    if (cv) return cv;
    for (UIViewController *child in vc.childViewControllers) {
        cv = rf_findCollectionViewInVC(child);
        if (cv) return cv;
    }
    return nil;
}

// ── RFCollectionWrapper: kept for backwards compatibility with older Reddit ──

@interface RFCollectionWrapper : NSObject <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, weak) id<UICollectionViewDataSource> origDS;
@property (nonatomic, weak) id<UICollectionViewDelegate>   origDel;
@end

@implementation RFCollectionWrapper

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    if ([self.origDS respondsToSelector:@selector(numberOfSectionsInCollectionView:)])
        return [self.origDS numberOfSectionsInCollectionView:cv];
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    NSInteger orig = [self.origDS collectionView:cv numberOfItemsInSection:section];
    return (section == 0) ? orig + 1 : orig;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.item == 0) {
        static NSString *cellID = @"RFSettingsCell";
        [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:cellID];
        UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:cellID
                                                                    forIndexPath:ip];
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
        for (UIGestureRecognizer *g in cell.gestureRecognizers) [cell removeGestureRecognizer:g];

        UIImageView *icon = [[UIImageView alloc] init];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        if (@available(iOS 13.0, *)) {
            icon.image = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"];
            icon.tintColor = [UIColor labelColor];
        }
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = @"RedditFilter Settings";
        label.font = [UIFont systemFontOfSize:17];
        if (@available(iOS 13.0, *))
            label.textColor = [UIColor labelColor];

        [cell.contentView addSubview:icon];
        [cell.contentView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],
            [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:22],
            [icon.heightAnchor constraintEqualToConstant:22],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-20],
        ]];
        cell.userInteractionEnabled = YES;
        cell.contentView.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(rfSettingsCellTapped:)];
        tap.numberOfTapsRequired = 1;
        [cell addGestureRecognizer:tap];
        return cell;
    }
    NSIndexPath *origIP = (ip.section == 0)
        ? [NSIndexPath indexPathForItem:ip.item - 1 inSection:ip.section] : ip;
    return [self.origDS collectionView:cv cellForItemAtIndexPath:origIP];
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.item == 0) {
        [cv deselectItemAtIndexPath:ip animated:YES];
        redditFilter_presentSettings(rf_topPresentableVC());
        return;
    }
    NSIndexPath *origIP = (ip.section == 0)
        ? [NSIndexPath indexPathForItem:ip.item - 1 inSection:ip.section] : ip;
    if ([self.origDel respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)])
        [self.origDel collectionView:cv didSelectItemAtIndexPath:origIP];
}

- (void)rfSettingsCellTapped:(UITapGestureRecognizer *)tap {
    redditFilter_presentSettings(rf_topPresentableVC());
}

- (BOOL)respondsToSelector:(SEL)sel {
    if ([super respondsToSelector:sel]) return YES;
    return [self.origDel respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    if ([self.origDel respondsToSelector:sel]) return self.origDel;
    return nil;
}

@end

// ── Button overlay approach for SwiftUI hosting controller ──────────────────

static void rf_addSettingsButtonToView(UIView *hostingView, UIViewController *parentVC) {
    // Avoid adding twice
    for (UIView *v in hostingView.subviews)
        if (v.tag == 0x5246) return;

    CGFloat safeBottom = hostingView.safeAreaInsets.bottom;
    CGFloat btnHeight  = 50.0;
    CGFloat btnY       = hostingView.bounds.size.height - btnHeight - safeBottom - 16.0;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = 0x5246;
    btn.frame = CGRectMake(0, btnY, hostingView.bounds.size.width, btnHeight);
    btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    btn.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 20);

    // Solid background so it's always visible on top of SwiftUI content
    if (@available(iOS 13.0, *)) {
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        UIImage *icon = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"];
        [btn setImage:icon forState:UIControlStateNormal];
        btn.tintColor = [UIColor labelColor];
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    } else {
        btn.backgroundColor = [UIColor whiteColor];
    }
    [btn setTitle:@"  RedditFilter Settings" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:17];

    // Separator line on top
    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
                                                                  hostingView.bounds.size.width,
                                                                  0.5)];
    separator.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (@available(iOS 13.0, *))
        separator.backgroundColor = [UIColor separatorColor];
    else
        separator.backgroundColor = [UIColor lightGrayColor];
    [btn addSubview:separator];

    [btn addTarget:parentVC
            action:@selector(redditFilter_settingsButtonTapped:)
  forControlEvents:UIControlEventTouchUpInside];

    [hostingView addSubview:btn];
    // Make sure our button is always on top of SwiftUI content
    [hostingView bringSubviewToFront:btn];
    rf_log(@"RedditFilter button added at y=%.1f safeBottom=%.1f", btnY, safeBottom);
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    NSString *n = NSStringFromClass(object_getClass(self));
    if (![n containsString:@"BottomSheet"]) return;

    // Idempotency guard
    if (objc_getAssociatedObject(self, kRFCollectionPatchedKey)) return;

    // Identify this as the profile "My Account" sheet by checking the child
    // hosting controller class name — it must contain "ProfileMyAccountSettings"
    BOOL isAccountSheet = NO;

    // Check child VCs for ProfileMyAccountSettings
    for (UIViewController *child in self.childViewControllers) {
        NSString *cn = NSStringFromClass(object_getClass(child));
        if ([cn containsString:@"ProfileMyAccountSettings"] ||
            [cn containsString:@"MyAccountSettings"]) {
            isAccountSheet = YES;
            break;
        }
    }

    // Also check the hosting view class name in the view hierarchy
    if (!isAccountSheet) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:self.view];
        while (queue.count && !isAccountSheet) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            NSString *vn = NSStringFromClass(object_getClass(v));
            if ([vn containsString:@"ProfileMyAccountSettings"] ||
                [vn containsString:@"MyAccountSettings"]) {
                isAccountSheet = YES;
            }
            [queue addObjectsFromArray:v.subviews];
        }
    }

    if (!isAccountSheet) {
        rf_log(@"BottomSheet: not the account sheet, skipping (%@)", n);
        return;
    }

    rf_log(@"BottomSheet: identified as account sheet");
    objc_setAssociatedObject(self, kRFCollectionPatchedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Try UICollectionView first (older Reddit versions)
    UICollectionView *cv = rf_findCollectionViewInVC(self);
    if (cv) {
        rf_log(@"BottomSheet: found UICollectionView, injecting wrapper");

        RFCollectionWrapper *wrapper = [[RFCollectionWrapper alloc] init];
        wrapper.origDS  = cv.dataSource;
        wrapper.origDel = cv.delegate;

        objc_setAssociatedObject(cv, kRFCollectionPatchedKey, wrapper,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cv.dataSource = wrapper;
        cv.delegate   = wrapper;
        [cv reloadData];
        return;
    }

    // Newer Reddit: pure SwiftUI — add button directly on the bottom sheet's
    // own view so it's guaranteed to be on top of the SwiftUI content.
    rf_log(@"BottomSheet: no UICollectionView, adding button overlay to sheet view");
    UIViewController *__weak weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *vc = weakSelf;
        if (!vc) return;
        rf_addSettingsButtonToView(vc.view, vc);
    });
}

%new
- (void)redditFilter_settingsButtonTapped:(UIButton *)sender {
    rf_log(@"RedditFilter Settings tapped via overlay button!");
    redditFilter_presentSettings(rf_topPresentableVC());
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
