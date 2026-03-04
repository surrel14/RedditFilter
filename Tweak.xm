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
// MARK: - INJECT "RedditFilter Settings" INTO THE PROFILE DRAWER TABLE VIEW
//
// Reddit's profile drawer is a UITableView (or a UICollectionView depending on
// the app version).  The safest injection point is the data-source protocol:
//
//  • numberOfRowsInSection: → return orig + 1 for section 0
//  • cellForRowAtIndexPath:  → return our custom cell for the last row
//  • didSelectRowAtIndexPath: → open FeedFilterSettingsViewController
//
// We only act when the table view belongs to a VC whose class name matches
// known Reddit profile / drawer class-name patterns, so we don't touch every
// UITableView in the app.
// ============================================================================

// Associated-object key: stores the original row count so we know our row index
static const void *kRFOrigRowCountKey = &kRFOrigRowCountKey;

// Returns YES if the table view lives inside Reddit's profile/account drawer
static BOOL rf_isProfileTableView(UITableView *tv) {
    UIResponder *r = tv;
    while ((r = r.nextResponder)) {
        if (![r isKindOfClass:[UIViewController class]]) continue;
        NSString *n = NSStringFromClass(object_getClass(r));
        if ([n containsString:@"Drawer"]        ||
            [n containsString:@"Profile"]       ||
            [n containsString:@"Account"]       ||
            [n containsString:@"UserMenu"]      ||
            [n containsString:@"SideMenu"]      ||
            [n containsString:@"SlideOut"]      ||
            [n containsString:@"AccountSwitcher"]) {
            return YES;
        }
        break; // stop at the first VC found
    }
    return NO;
}

// Walk up the responder chain to find a UIViewController
static UIViewController *rf_owningVC(UIView *view) {
    UIResponder *r = view;
    while ((r = r.nextResponder))
        if ([r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
    return nil;
}

// Walk to the root presenting VC so we can present the settings sheet over everything
static UIViewController *rf_rootPresentingVC(UIViewController *vc) {
    UIViewController *root = vc;
    // Go up to the top of the container hierarchy
    while (root.parentViewController) root = root.parentViewController;
    // The drawer is presented modally; we want the VC that presented it
    UIViewController *presenter = root.presentingViewController;
    if (presenter) {
        // Resolve any nested nav controllers
        while ([presenter isKindOfClass:[UINavigationController class]])
            presenter = [(UINavigationController *)presenter topViewController];
        return presenter;
    }
    return root;
}

%hook NSObject

// ── numberOfRowsInSection: ──────────────────────────────────────────────────
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger orig = %orig;
    if (section != 0 || !rf_isProfileTableView(tableView)) return orig;

    // Store the original count keyed to this table view instance
    objc_setAssociatedObject(tableView,
                             kRFOrigRowCountKey,
                             @(orig),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return orig + 1; // add our row
}

// ── cellForRowAtIndexPath: ──────────────────────────────────────────────────
- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    if (indexPath.section != 0 || !rf_isProfileTableView(tableView)) return %orig;

    NSNumber *origCount = objc_getAssociatedObject(tableView, kRFOrigRowCountKey);
    if (!origCount || indexPath.row != origCount.integerValue) return %orig;

    // ── Build our custom cell ──
    static NSString *cellID = @"RedditFilterSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID];
    }

    cell.textLabel.text = @"RedditFilter Settings";
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;

    // SF Symbol icon (iOS 13+), plain fallback for older deployments
    UIImage *icon = nil;
    if (@available(iOS 13.0, *)) {
        icon = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"];
        if (!icon) icon = [UIImage systemImageNamed:@"gearshape"];
        if (!icon) icon = [UIImage systemImageNamed:@"gear"];
    }
    cell.imageView.image      = icon;
    cell.imageView.tintColor  = tableView.tintColor ?: [UIColor systemBlueColor];

    return cell;
}

// ── didSelectRowAtIndexPath: ────────────────────────────────────────────────
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0 || !rf_isProfileTableView(tableView)) {
        %orig;
        return;
    }
    NSNumber *origCount = objc_getAssociatedObject(tableView, kRFOrigRowCountKey);
    if (!origCount || indexPath.row != origCount.integerValue) {
        %orig;
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSLog(@"[RedditFilter] 'RedditFilter Settings' tapped in profile drawer");

    UIViewController *ownerVC = rf_owningVC(tableView);
    UIViewController *presenterVC = ownerVC ? rf_rootPresentingVC(ownerVC) : nil;

    if (!presenterVC) {
        // Last-resort: use the key window's root VC
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.isKeyWindow) continue;
            presenterVC = w.rootViewController;
            while (presenterVC.presentedViewController)
                presenterVC = presenterVC.presentedViewController;
            break;
        }
    }

    if (presenterVC) redditFilter_presentSettings(presenterVC);
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
