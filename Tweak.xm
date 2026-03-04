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
// MARK: - INJECT "RedditFilter Settings" INTO THE NATIVE ACTION SHEET
//
// When the three-lines button is tapped inside the profile drawer, Reddit
// presents a UIAlertController (action sheet style) with its native options.
// We hook -[UIViewController presentViewController:animated:completion:] and,
// whenever a UIAlertController of style ActionSheet is about to be presented
// from a drawer VC, we append our custom "RedditFilter Settings" action before
// letting the original presentation proceed.
// ============================================================================

// Walk up the responder chain / parent chain to find the topmost presenting VC
static UIViewController *rf_rootPresentingVC(UIViewController *vc) {
    UIViewController *root = vc;
    while (root.parentViewController) root = root.parentViewController;
    UIViewController *presenter = root.presentingViewController;
    if (presenter) {
        while ([presenter isKindOfClass:[UINavigationController class]])
            presenter = [(UINavigationController *)presenter topViewController];
        return presenter;
    }
    return root;
}

// Returns YES if this VC is Reddit's profile / account drawer
static BOOL rf_isDrawerVC(UIViewController *vc) {
    NSString *n = NSStringFromClass(object_getClass(vc));
    return [n containsString:@"Drawer"]          ||
           [n containsString:@"Profile"]         ||
           [n containsString:@"Account"]         ||
           [n containsString:@"UserMenu"]        ||
           [n containsString:@"SideMenu"]        ||
           [n containsString:@"SlideOut"]        ||
           [n containsString:@"AccountSwitcher"];
}

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {

    // Only act when the presenting VC is Reddit's profile drawer
    if (!rf_isDrawerVC(self)) {
        %orig;
        return;
    }

    // Only inject into UIAlertController action sheets
    if (![viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        %orig;
        return;
    }

    UIAlertController *alert = (UIAlertController *)viewControllerToPresent;
    if (alert.preferredStyle != UIAlertControllerStyleActionSheet) {
        %orig;
        return;
    }

    NSLog(@"[RedditFilter] Injecting action into native action sheet from drawer VC: %@",
          NSStringFromClass(object_getClass(self)));

    // Keep a weak reference to self for the block
    __weak UIViewController *weakSelf = self;

    UIAlertAction *filterAction = [UIAlertAction
        actionWithTitle:@"RedditFilter Settings"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    UIViewController *presenter = rf_rootPresentingVC(weakSelf);
                    redditFilter_presentSettings(presenter);
                }];

    // Insert before the Cancel action (if any), otherwise append at the end
    NSArray<UIAlertAction *> *existing = alert.actions;
    BOOL hasCancelAtEnd = existing.count > 0 &&
                          existing.lastObject.style == UIAlertActionStyleCancel;

    if (hasCancelAtEnd) {
        // UIAlertController doesn't support inserting at index directly;
        // we must re-add all actions in the desired order.
        // Save existing actions, clear them, re-add with ours before Cancel.
        NSMutableArray *nonCancel = [NSMutableArray array];
        UIAlertAction *cancelAction = nil;
        for (UIAlertAction *a in existing) {
            if (a.style == UIAlertActionStyleCancel) cancelAction = a;
            else [nonCancel addObject:a];
        }
        // UIAlertController has no public removeAction: API, so we use KVC
        // to replace the actions array directly.
        NSMutableArray *newActions = [NSMutableArray arrayWithArray:nonCancel];
        [newActions addObject:filterAction];
        if (cancelAction) [newActions addObject:cancelAction];
        [alert setValue:newActions forKey:@"actions"];
    } else {
        [alert addAction:filterAction];
    }

    %orig;
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
