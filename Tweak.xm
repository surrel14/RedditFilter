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
- (instancetype)initWithName:(NSString *)name
                   fromBundle:(NSBundle *)bundle;
- (instancetype)initWithName:(NSString *)name
                   fromBundle:(NSBundle *)bundle
                        error:(NSError **)error;

@end

static NSMutableArray<NSBundle *> *assetBundles;
static NSMutableArray<CUICatalog *> *assetCatalogs;

extern "C" UIImage *iconWithName(NSString *iconName) {
  for (CUICatalog *catalog in assetCatalogs) {
    for (NSString *imageName in [catalog allImageNames]) {
      if ([imageName hasPrefix:iconName] &&
          (imageName.length == iconName.length ||
           imageName.length == iconName.length + 3)) {

        return [UIImage imageNamed:imageName
                          inBundle:object_getIvar(
                                      catalog,
                                      class_getInstanceVariable(
                                          object_getClass(catalog),
                                          "_bundle"))
         compatibleWithTraitCollection:nil];
      }
    }
  }

  return nil;
}

extern "C" NSString *localizedString(NSString *key, NSString *table) {
  for (NSBundle *bundle in assetBundles) {
    NSString *localizedString =
        [bundle localizedStringForKey:key
                                value:nil
                                table:table];

    if (![localizedString isEqualToString:key]) {
      return localizedString;
    }
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
    if (cls) {
      break;
    }

    cls = NSClassFromString(
        [prefix stringByAppendingString:name]);
  }

  return cls;
}

// ============================================================================
// MARK: - FILTER HELPERS
// ============================================================================

static BOOL shouldFilterObject(id object) {
  if (!object) {
    return NO;
  }

  NSString *className =
      NSStringFromClass(object_getClass(object));

  BOOL isAdPost =
      [className hasSuffix:@"AdPost"] ||
      ([object respondsToSelector:@selector(isAdPost)] &&
       ((Post *)object).isAdPost) ||
      ([object respondsToSelector:@selector(isPromotedUserPostAd)] &&
       [(Post *)object isPromotedUserPostAd]) ||
      ([object respondsToSelector:@selector(isPromotedCommunityPostAd)] &&
       [(Post *)object isPromotedCommunityPostAd]);

  BOOL isRecommendation =
      [className containsString:@"Recommend"];

  BOOL isNSFW =
      [object respondsToSelector:@selector(isNSFW)] &&
      ((Post *)object).isNSFW;

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterPromoted] &&
      isAdPost) {
    return YES;
  }

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterRecommended] &&
      isRecommendation) {
    return YES;
  }

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterNSFW] &&
      isNSFW) {
    return YES;
  }

  return NO;
}

static NSArray *filteredObjects(NSArray *objects) {
  if (!objects) {
    return objects;
  }

  return [objects
      filteredArrayUsingPredicate:
          [NSPredicate predicateWithBlock:^BOOL(
              id object,
              NSDictionary *bindings) {

            return !shouldFilterObject(object);
          }]];
}

// ============================================================================
// MARK: - JSON FILTER
// ============================================================================

static void filterNode(NSMutableDictionary *node) {
  if (![node isKindOfClass:NSMutableDictionary.class]) {
    return;
  }

  NSString *type =
      [node[@"__typename"] isKindOfClass:NSString.class]
          ? node[@"__typename"]
          : nil;

  // --------------------------------------------------------------------------
  // SubredditPost
  // --------------------------------------------------------------------------

  if ([type isEqualToString:@"SubredditPost"]) {

    if ([NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterAwards]) {

      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }

    if ([NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterScores]) {

      node[@"isScoreHidden"] = @YES;
    }

    if ([NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterNSFW] &&
        [node[@"isNsfw"] boolValue]) {

      node[@"isHidden"] = @YES;
    }
  }

  // --------------------------------------------------------------------------
  // CellGroup
  // --------------------------------------------------------------------------

  if ([type isEqualToString:@"CellGroup"]) {

    id cellsObject = node[@"cells"];

    if ([cellsObject isKindOfClass:NSArray.class]) {

      for (NSMutableDictionary *cell in cellsObject) {

        if (![cell isKindOfClass:NSMutableDictionary.class]) {
          continue;
        }

        if ([cell[@"__typename"]
                isEqualToString:@"ActionCell"]) {

          if ([NSUserDefaults.standardUserDefaults
                  boolForKey:kRedditFilterAwards]) {

            cell[@"isAwardHidden"] = @YES;

            id goldenUpvoteInfo =
                cell[@"goldenUpvoteInfo"];

            if ([goldenUpvoteInfo
                    isKindOfClass:NSDictionary.class] &&
                ![goldenUpvoteInfo
                    isEqual:[NSNull null]]) {

              if ([goldenUpvoteInfo
                      isKindOfClass:NSMutableDictionary.class]) {

                ((NSMutableDictionary *)goldenUpvoteInfo)
                    [@"isGildable"] = @NO;
              } else {

                NSMutableDictionary *mutableInfo =
                    [goldenUpvoteInfo mutableCopy];

                mutableInfo[@"isGildable"] = @NO;

                cell[@"goldenUpvoteInfo"] =
                    mutableInfo;
              }
            }
          }

          if ([NSUserDefaults.standardUserDefaults
                  boolForKey:kRedditFilterScores]) {

            cell[@"isScoreHidden"] = @YES;
          }
        }
      }
    }

    // ------------------------------------------------------------------------
    // Promoted CellGroup
    // ------------------------------------------------------------------------

    if ([NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterPromoted] &&
        [node[@"adPayload"]
            isKindOfClass:NSDictionary.class]) {

      node[@"cells"] = @[];
    }

    // ------------------------------------------------------------------------
    // Recommended CellGroup
    // ------------------------------------------------------------------------

    if ([NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterRecommended] &&
        ![node[@"recommendationContext"]
            isEqual:[NSNull null]] &&
        [node[@"recommendationContext"]
            isKindOfClass:NSDictionary.class]) {

      NSDictionary *recommendationContext =
          node[@"recommendationContext"];

      id typeName =
          recommendationContext[@"typeName"];

      id typeIdentifier =
          recommendationContext[@"typeIdentifier"];

      id isContextHidden =
          recommendationContext[@"isContextHidden"];

      if (![typeIdentifier isEqual:[NSNull null]] &&
          ![typeName isEqual:[NSNull null]] &&
          ![isContextHidden isEqual:[NSNull null]] &&
          [typeIdentifier isKindOfClass:NSString.class] &&
          [typeName isKindOfClass:NSString.class] &&
          [isContextHidden isKindOfClass:NSNumber.class]) {

        BOOL isPopularContext =
            [typeName
                isEqualToString:@"PopularRecommendationContext"] ||
            [typeIdentifier
                hasPrefix:@"global_popular"];

        if (!(isPopularContext &&
              [isContextHidden boolValue])) {

          node[@"cells"] = @[];
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // AdPost
  // --------------------------------------------------------------------------

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterPromoted]) {

    if ([type isEqualToString:@"AdPost"]) {
      node[@"isHidden"] = @YES;
    }
  }

  // --------------------------------------------------------------------------
  // Comment
  // --------------------------------------------------------------------------

  if ([type isEqualToString:@"Comment"]) {

    if ([NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterAwards]) {

      node[@"awardings"] = @[];
      node[@"isGildable"] = @NO;
    }

    if ([NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterScores]) {

      node[@"isScoreHidden"] = @YES;
    }

    if ([node[@"authorInfo"]
            isKindOfClass:NSDictionary.class] &&
        [node[@"authorInfo"][@"id"]
            isEqualToString:@"t2_6l4z3"] &&
        [NSUserDefaults.standardUserDefaults
            boolForKey:kRedditFilterAutoCollapseAutoMod]) {

      node[@"isInitiallyCollapsed"] = @YES;
    }
  }
}

// ============================================================================
// MARK: - NETWORK FILTER
// ============================================================================

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:
                                (void (^)(NSData *data,
                                          NSURLResponse *response,
                                          NSError *error))completionHandler {

  NSString *host = request.URL.host;

  if (![host hasPrefix:@"gql"] &&
      ![host hasPrefix:@"oauth"]) {

    return %orig;
  }

  void (^newCompletionHandler)(
      NSData *,
      NSURLResponse *,
      NSError *) =
      ^(NSData *data,
        NSURLResponse *response,
        NSError *error) {

        if (error || !data) {
          completionHandler(data, response, error);
          return;
        }

        NSDictionary *json =
            [NSJSONSerialization
                JSONObjectWithData:data
                           options:NSJSONReadingMutableContainers
                             error:&error];

        if (error || !json) {
          completionHandler(data, response, error);
          return;
        }

        if ([json isKindOfClass:NSDictionary.class]) {

          id jsonData = json[@"data"];

          if ([jsonData isKindOfClass:NSDictionary.class]) {

            NSDictionary *dataDictionary =
                (NSDictionary *)jsonData;

            id firstValue =
                dataDictionary.allValues.firstObject;

            NSMutableDictionary *root = nil;

            if ([firstValue
                    isKindOfClass:NSDictionary.class]) {

              root =
                  [(NSDictionary *)firstValue
                      mutableCopy];
            }

            if (root) {

              // --------------------------------------------------------------
              // Edges
              // --------------------------------------------------------------

              id firstRootValue =
                  root.allValues.firstObject;

              if ([firstRootValue
                      isKindOfClass:NSDictionary.class]) {

                NSDictionary *firstDictionary =
                    (NSDictionary *)firstRootValue;

                id edges =
                    firstDictionary[@"edges"];

                if ([edges isKindOfClass:NSArray.class]) {

                  for (id edge in edges) {

                    if ([edge
                            isKindOfClass:NSDictionary.class]) {

                      id node =
                          [(NSDictionary *)edge objectForKey:@"node"];

                      if ([node
                              isKindOfClass:
                                  NSMutableDictionary.class]) {

                        filterNode(node);

                      } else if ([node
                                     isKindOfClass:
                                         NSDictionary.class]) {

                        NSMutableDictionary *mutableNode =
                            [node mutableCopy];

                        filterNode(mutableNode);
                      }
                    }
                  }
                }
              }

              // --------------------------------------------------------------
              // Comment forest
              // --------------------------------------------------------------

              id commentForest =
                  root[@"commentForest"];

              if ([commentForest
                      isKindOfClass:NSDictionary.class]) {

                id trees =
                    commentForest[@"trees"];

                if ([trees isKindOfClass:NSArray.class]) {

                  for (id tree in trees) {

                    if (![tree
                            isKindOfClass:
                                NSDictionary.class]) {
                      continue;
                    }

                    id node =
                        tree[@"node"];

                    if ([node
                            isKindOfClass:
                                NSMutableDictionary.class]) {

                      filterNode(node);
                    }
                  }
                }
              }

              // --------------------------------------------------------------
              // Ads
              // --------------------------------------------------------------

              if (root[@"commentsPageAds"] &&
                  [NSUserDefaults.standardUserDefaults
                      boolForKey:kRedditFilterPromoted]) {

                root[@"commentsPageAds"] = @[];
              }

              if (root[@"commentTreeAds"] &&
                  [NSUserDefaults.standardUserDefaults
                      boolForKey:kRedditFilterPromoted]) {

                root[@"commentTreeAds"] = @[];
              }

              if (root[@"pdpCommentsAds"] &&
                  [NSUserDefaults.standardUserDefaults
                      boolForKey:kRedditFilterPromoted]) {

                root[@"pdpCommentsAds"] = @[];
              }

              // --------------------------------------------------------------
              // Recommendations
              // --------------------------------------------------------------

              if (root[@"recommendations"] &&
                  [NSUserDefaults.standardUserDefaults
                      boolForKey:kRedditFilterRecommended]) {

                root[@"recommendations"] = @[];
              }

            } else if ([firstValue
                           isKindOfClass:NSArray.class]) {

              for (id node in
                   (NSArray *)firstValue) {

                if ([node
                        isKindOfClass:
                            NSMutableDictionary.class]) {

                  filterNode(node);
                }
              }
            }
          }
        }

        NSData *filteredData =
            [NSJSONSerialization
                dataWithJSONObject:json
                           options:0
                             error:nil];

        completionHandler(
            filteredData ?: data,
            response,
            error);
      };

  return %orig(request, newCompletionHandler);
}

%end

// ============================================================================
// MARK: - SETTINGS PRESENTATION
// ============================================================================

static void redditFilter_presentSettings(
    UIViewController *fromVC) {

  if (!fromVC) {
    NSLog(@"[RedditFilter] ERROR: No presenting view controller");
    return;
  }

  Class filterVCClass =
      NSClassFromString(
          @"FeedFilterSettingsViewController");

  if (!filterVCClass) {

    NSLog(@"[RedditFilter] ERROR: FeedFilterSettingsViewController class not found");

    return;
  }

  UIViewController *filterVC =
      [[filterVCClass alloc] init];

  UINavigationController *nav =
      [[UINavigationController alloc]
          initWithRootViewController:filterVC];

  if (fromVC.presentedViewController) {

    [fromVC dismissViewControllerAnimated:YES
                               completion:^{

      [fromVC presentViewController:nav
                           animated:YES
                         completion:nil];
    }];

  } else {

    [fromVC presentViewController:nav
                         animated:YES
                       completion:nil];
  }
}

// ============================================================================
// MARK: - DEBUG LOGGER
// ============================================================================

static NSMutableArray<NSString *> *rf_debugLines;

static void rf_log(NSString *format, ...) {

  va_list args;

  va_start(args, format);

  NSString *msg =
      [[NSString alloc]
          initWithFormat:format
               arguments:args];

  va_end(args);

  NSLog(@"[RedditFilter] %@", msg);

  if (!rf_debugLines) {
    rf_debugLines =
        [NSMutableArray array];
  }

  NSString *timestamp =
      [NSDateFormatter
          localizedStringFromDate:[NSDate date]
                         dateStyle:NSDateFormatterNoStyle
                         timeStyle:NSDateFormatterMediumStyle];

  [rf_debugLines addObject:
      [NSString stringWithFormat:@"[%@] %@",
                                 timestamp,
                                 msg]];

  while (rf_debugLines.count > 60) {
    [rf_debugLines removeObjectAtIndex:0];
  }
}

static void rf_showDebugLog(void) {

  NSString *logText =
      rf_debugLines.count
          ? [rf_debugLines
                componentsJoinedByString:@"\n"]
          : @"(no logs yet)";

  UIAlertController *alert =
      [UIAlertController
          alertControllerWithTitle:
              @"RedditFilter Debug Log"
                           message:logText
                    preferredStyle:
                        UIAlertControllerStyleAlert];

  [alert addAction:
      [UIAlertAction
          actionWithTitle:@"Copy to Clipboard"
                    style:UIAlertActionStyleDefault
                  handler:^(UIAlertAction *action) {

                    [UIPasteboard generalPasteboard].string =
                        logText;
                  }]];

  [alert addAction:
      [UIAlertAction
          actionWithTitle:@"Clear & Close"
                    style:UIAlertActionStyleDestructive
                  handler:^(UIAlertAction *action) {

                    [rf_debugLines removeAllObjects];
                  }]];

  [alert addAction:
      [UIAlertAction
          actionWithTitle:@"Close"
                    style:UIAlertActionStyleCancel
                  handler:nil]];

  UIViewController *top = nil;

  for (UIWindow *window
       in UIApplication.sharedApplication.windows) {

    if (window.isKeyWindow) {

      top =
          window.rootViewController;

      break;
    }
  }

  while (top.presentedViewController) {
    top =
        top.presentedViewController;
  }

  if (top) {

    [top presentViewController:alert
                      animated:YES
                    completion:nil];
  }
}

// ============================================================================
// MARK: - DEBUG UIViewController
// ============================================================================

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {

  rf_log(@"present: %@ from: %@",
         NSStringFromClass(object_getClass(vc)),
         NSStringFromClass(object_getClass(self)));

  if ([vc isKindOfClass:[UIAlertController class]]) {

    UIAlertController *alert =
        (UIAlertController *)vc;

    rf_log(@"  AlertController style=%ld title='%@'",
           (long)alert.preferredStyle,
           alert.title);

    for (UIAlertAction *action
         in alert.actions) {

      rf_log(@"    action:'%@' style=%ld",
             action.title,
             (long)action.style);
    }
  }

  %orig;
}

%end

// ============================================================================
// MARK: - TOP VIEW CONTROLLER
// ============================================================================

static UIViewController *rf_topPresentableVC(void) {

  UIWindow *keyWindow = nil;

  for (UIWindow *window
       in UIApplication.sharedApplication.windows) {

    if (window.isKeyWindow) {

      keyWindow = window;
      break;
    }
  }

  if (!keyWindow) {
    return nil;
  }

  UIViewController *vc =
      keyWindow.rootViewController;

  while (vc.presentedViewController) {
    vc =
        vc.presentedViewController;
  }

  if ([vc
          isKindOfClass:
              [UINavigationController class]]) {

    vc =
        [(UINavigationController *)vc
            topViewController];
  }

  return vc;
}

// ============================================================================
// MARK: - THREE FINGER GESTURES
// ============================================================================

%hook UIWindow

- (void)becomeKeyWindow {

  %orig;

  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{

    // 3 finger / 1 second = settings

    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(
                        redditFilter_handleThreeFingerLongPress:)];

    longPress.numberOfTouchesRequired = 3;
    longPress.minimumPressDuration = 1.0;

    [self addGestureRecognizer:longPress];

    // 3 finger / 0.1 second = debug log

    UILongPressGestureRecognizer *shortPress =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(
                        redditFilter_handleThreeFingerShortPress:)];

    shortPress.numberOfTouchesRequired = 3;
    shortPress.minimumPressDuration = 0.1;

    [self addGestureRecognizer:shortPress];

    NSLog(@"[RedditFilter] 3-finger gestures installed");
  });
}

%new
- (void)redditFilter_handleThreeFingerLongPress:
    (UILongPressGestureRecognizer *)gesture {

  if (gesture.state !=
      UIGestureRecognizerStateBegan) {

    return;
  }

  rf_log(@"3-finger long press → opening settings");

  UIViewController *top =
      rf_topPresentableVC();

  if (top) {
    redditFilter_presentSettings(top);
  }
}

%new
- (void)redditFilter_handleThreeFingerShortPress:
    (UILongPressGestureRecognizer *)gesture {

  if (gesture.state !=
      UIGestureRecognizerStateBegan) {

    return;
  }

  rf_log(@"3-finger short press → showing debug log");

  rf_showDebugLog();
}

%end

// ============================================================================
// MARK: - COLLECTION VIEW HELPERS
// ============================================================================

static const void *kRFCollectionPatchedKey =
    &kRFCollectionPatchedKey;

static UICollectionView *rf_findCollectionView(
    UIView *root) {

  if ([root
          isKindOfClass:
              [UICollectionView class]]) {

    return (UICollectionView *)root;
  }

  for (UIView *subview
       in root.subviews) {

    UICollectionView *collectionView =
        rf_findCollectionView(subview);

    if (collectionView) {
      return collectionView;
    }
  }

  return nil;
}

static UICollectionView *rf_findCollectionViewInVC(
    UIViewController *vc) {

  UICollectionView *collectionView =
      rf_findCollectionView(vc.view);

  if (collectionView) {
    return collectionView;
  }

  for (UIViewController *child
       in vc.childViewControllers) {

    collectionView =
        rf_findCollectionViewInVC(child);

    if (collectionView) {
      return collectionView;
    }
  }

  return nil;
}

// ============================================================================
// MARK: - COLLECTION WRAPPER
// ============================================================================

@interface RFCollectionWrapper
    : NSObject
    <UICollectionViewDataSource, UICollectionViewDelegate>

@property (nonatomic, weak)
    id<UICollectionViewDataSource> origDS;

@property (nonatomic, weak)
    id<UICollectionViewDelegate> origDel;

@end

@implementation RFCollectionWrapper

- (NSInteger)numberOfSectionsInCollectionView:
    (UICollectionView *)collectionView {

  if ([self.origDS
          respondsToSelector:
              @selector(numberOfSectionsInCollectionView:)]) {

    return
        [self.origDS
            numberOfSectionsInCollectionView:
                collectionView];
  }

  return 1;
}

- (NSInteger)collectionView:
    (UICollectionView *)collectionView
    numberOfItemsInSection:(NSInteger)section {

  if (!self.origDS) {
    return section == 0 ? 1 : 0;
  }

  NSInteger originalCount =
      [self.origDS
          collectionView:collectionView
          numberOfItemsInSection:section];

  return section == 0
             ? originalCount + 1
             : originalCount;
}

- (UICollectionViewCell *)collectionView:
    (UICollectionView *)collectionView
    cellForItemAtIndexPath:(NSIndexPath *)indexPath {

  // Our settings cell
  if (indexPath.section == 0 &&
      indexPath.item == 0) {

    static NSString *cellID =
        @"RFSettingsCell";

    [collectionView
        registerClass:[UICollectionViewCell class]
        forCellWithReuseIdentifier:cellID];

    UICollectionViewCell *cell =
        [collectionView
            dequeueReusableCellWithReuseIdentifier:
                cellID
                                      forIndexPath:
                                          indexPath];

    for (UIView *view
         in cell.contentView.subviews) {

      [view removeFromSuperview];
    }

    for (UIGestureRecognizer *gesture
         in cell.gestureRecognizers) {

      [cell removeGestureRecognizer:gesture];
    }

    UIImageView *icon =
        [[UIImageView alloc] init];

    icon.translatesAutoresizingMaskIntoConstraints =
        NO;

    icon.contentMode =
        UIViewContentModeScaleAspectFit;

    if (@available(iOS 13.0, *)) {

      icon.image =
          [UIImage
              systemImageNamed:
                  @"line.3.horizontal.decrease.circle"];

      icon.tintColor =
          [UIColor labelColor];
    }

    UILabel *label =
        [[UILabel alloc] init];

    label.translatesAutoresizingMaskIntoConstraints =
        NO;

    label.text =
        @"RedditFilter Settings";

    label.font =
        [UIFont systemFontOfSize:17];

    if (@available(iOS 13.0, *)) {

      label.textColor =
          [UIColor labelColor];
    }

    [cell.contentView addSubview:icon];
    [cell.contentView addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
      [icon.leadingAnchor
          constraintEqualToAnchor:
              cell.contentView.leadingAnchor
          constant:20.0],

      [icon.centerYAnchor
          constraintEqualToAnchor:
              cell.contentView.centerYAnchor],

      [icon.widthAnchor
          constraintEqualToConstant:22.0],

      [icon.heightAnchor
          constraintEqualToConstant:22.0],

      [label.leadingAnchor
          constraintEqualToAnchor:
              icon.trailingAnchor
          constant:14.0],

      [label.centerYAnchor
          constraintEqualToAnchor:
              cell.contentView.centerYAnchor],

      [label.trailingAnchor
          constraintEqualToAnchor:
              cell.contentView.trailingAnchor
          constant:-20.0]
    ]];

    cell.userInteractionEnabled = YES;
    cell.contentView.userInteractionEnabled = YES;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(
                        rfSettingsCellTapped:)];

    tap.numberOfTapsRequired = 1;

    [cell addGestureRecognizer:tap];

    return cell;
  }

  // Original Reddit cell
  NSIndexPath *originalIndexPath =
      indexPath.section == 0
          ? [NSIndexPath
                indexPathForItem:indexPath.item - 1
                inSection:indexPath.section]
          : indexPath;

  if ([self.origDS
          respondsToSelector:
              @selector(collectionView:
                       cellForItemAtIndexPath:)]) {

    return
        [self.origDS
            collectionView:collectionView
            cellForItemAtIndexPath:
                originalIndexPath];
  }

  return [UICollectionViewCell new];
}

- (void)collectionView:
    (UICollectionView *)collectionView
    didSelectItemAtIndexPath:
        (NSIndexPath *)indexPath {

  if (indexPath.section == 0 &&
      indexPath.item == 0) {

    [collectionView
        deselectItemAtIndexPath:indexPath
                       animated:YES];

    UIViewController *top =
        rf_topPresentableVC();

    if (top) {
      redditFilter_presentSettings(top);
    }

    return;
  }

  NSIndexPath *originalIndexPath =
      indexPath.section == 0
          ? [NSIndexPath
                indexPathForItem:indexPath.item - 1
                inSection:indexPath.section]
          : indexPath;

  if ([self.origDel
          respondsToSelector:
              @selector(collectionView:
                       didSelectItemAtIndexPath:)]) {

    [self.origDel
        collectionView:collectionView
        didSelectItemAtIndexPath:
            originalIndexPath];
  }
}

- (void)rfSettingsCellTapped:
    (UITapGestureRecognizer *)gesture {

  UIViewController *top =
      rf_topPresentableVC();

  if (top) {
    redditFilter_presentSettings(top);
  }
}

- (BOOL)respondsToSelector:(SEL)selector {

  if ([super respondsToSelector:selector]) {
    return YES;
  }

  return [self.origDel
      respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:
    (SEL)selector {

  if ([self.origDel
          respondsToSelector:selector]) {

    return self.origDel;
  }

  return nil;
}

@end

// ============================================================================
// MARK: - SWIFTUI BUTTON OVERLAY
// ============================================================================

static void rf_addSettingsButtonToView(
    UIView *hostingView,
    UIViewController *parentVC) {

  if (!hostingView ||
      !parentVC) {

    return;
  }

  // Prevent duplicates
  for (UIView *view
       in hostingView.subviews) {

    if (view.tag == 0x5246) {
      return;
    }
  }

  CGFloat buttonHeight = 50.0;

  CGFloat contentMaxY = 0;

  for (UIView *subview
       in hostingView.subviews) {

    if (subview.tag == 0x5246) {
      continue;
    }

    CGFloat subviewMaxY =
        CGRectGetMaxY(subview.frame);

    if (subviewMaxY > contentMaxY &&
        subviewMaxY <
            hostingView.bounds.size.height - 50.0) {

      contentMaxY = subviewMaxY;
    }
  }

  if (contentMaxY < 100.0) {

    contentMaxY =
        hostingView.bounds.size.height * 0.60;
  }

  CGFloat buttonY =
      contentMaxY - 50.0;

  if (buttonY < 0) {
    buttonY = 0;
  }

  rf_log(@"contentMaxY=%.1f buttonY=%.1f bounds.h=%.1f",
         contentMaxY,
         buttonY,
         hostingView.bounds.size.height);

  UIButton *button =
      [UIButton buttonWithType:
                    UIButtonTypeSystem];

  button.tag = 0x5246;

  button.frame =
      CGRectMake(
          0,
          buttonY,
          hostingView.bounds.size.width,
          buttonHeight);

  button.autoresizingMask =
      UIViewAutoresizingFlexibleWidth |
      UIViewAutoresizingFlexibleTopMargin;

  button.contentHorizontalAlignment =
      UIControlContentHorizontalAlignmentLeft;

  button.contentEdgeInsets =
      UIEdgeInsetsMake(0, 20, 0, 20);

  if (@available(iOS 13.0, *)) {

    UIImage *icon =
        [UIImage
            systemImageNamed:
                @"line.3.horizontal.decrease.circle"];

    [button setImage:icon
            forState:UIControlStateNormal];

    button.tintColor =
        [UIColor labelColor];

    [button setTitleColor:
                [UIColor labelColor]
                  forState:UIControlStateNormal];
  }

  [button
      setTitle:@"  RedditFilter Settings"
      forState:UIControlStateNormal];

  button.titleLabel.font =
      [UIFont systemFontOfSize:17];

  UIView *separator =
      [[UIView alloc]
          initWithFrame:
              CGRectMake(
                  0,
                  0,
                  hostingView.bounds.size.width,
                  0.5)];

  separator.autoresizingMask =
      UIViewAutoresizingFlexibleWidth;

  if (@available(iOS 13.0, *)) {

    separator.backgroundColor =
        [UIColor separatorColor];

  } else {

    separator.backgroundColor =
        [UIColor lightGrayColor];
  }

  [button addSubview:separator];

  [button
      addTarget:parentVC
      action:@selector(
          redditFilter_settingsButtonTapped:)
      forControlEvents:
          UIControlEventTouchUpInside];

  [hostingView addSubview:button];

  [hostingView bringSubviewToFront:button];

  rf_log(@"RedditFilter button added at y=%.1f",
         buttonY);
}

// ============================================================================
// MARK: - BOTTOM SHEET HOOK
// ============================================================================

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {

  %orig;

  NSString *className =
      NSStringFromClass(object_getClass(self));

  if (![className containsString:@"BottomSheet"]) {
    return;
  }

  // Idempotency guard
  if (objc_getAssociatedObject(
          self,
          kRFCollectionPatchedKey)) {

    return;
  }

  BOOL isAccountSheet = NO;

  // Check child view controllers
  for (UIViewController *child
       in self.childViewControllers) {

    NSString *childClassName =
        NSStringFromClass(
            object_getClass(child));

    if ([childClassName
            containsString:
                @"ProfileMyAccountSettings"] ||
        [childClassName
            containsString:
                @"MyAccountSettings"]) {

      isAccountSheet = YES;
      break;
    }
  }

  // Check view hierarchy
  if (!isAccountSheet) {

    NSMutableArray *queue =
        [NSMutableArray
            arrayWithObject:self.view];

    while (queue.count &&
           !isAccountSheet) {

      UIView *view =
          queue.firstObject;

      [queue removeObjectAtIndex:0];

      NSString *viewClassName =
          NSStringFromClass(
              object_getClass(view));

      if ([viewClassName
              containsString:
                  @"ProfileMyAccountSettings"] ||
          [viewClassName
              containsString:
                  @"MyAccountSettings"]) {

        isAccountSheet = YES;
        break;
      }

      [queue addObjectsFromArray:
                 view.subviews];
    }
  }

  if (!isAccountSheet) {

    rf_log(@"BottomSheet: not the account sheet, skipping (%@)",
           className);

    return;
  }

  rf_log(@"BottomSheet: identified as account sheet");

  objc_setAssociatedObject(
      self,
      kRFCollectionPatchedKey,
      @YES,
      OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  // --------------------------------------------------------------------------
  // Older Reddit versions
  // --------------------------------------------------------------------------

  UICollectionView *collectionView =
      rf_findCollectionViewInVC(self);

  if (collectionView) {

    rf_log(@"BottomSheet: found UICollectionView, injecting wrapper");

    RFCollectionWrapper *wrapper =
        [[RFCollectionWrapper alloc] init];

    wrapper.origDS =
        collectionView.dataSource;

    wrapper.origDel =
        collectionView.delegate;

    objc_setAssociatedObject(
        collectionView,
        kRFCollectionPatchedKey,
        wrapper,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    collectionView.dataSource =
        wrapper;

    collectionView.delegate =
        wrapper;

    [collectionView reloadData];

    return;
  }

  // --------------------------------------------------------------------------
  // Newer Reddit versions / SwiftUI
  // --------------------------------------------------------------------------

  rf_log(@"BottomSheet: no UICollectionView, adding button overlay to sheet view");

  UIViewController *__weak weakSelf =
      self;

  dispatch_after(
      dispatch_time(
          DISPATCH_TIME_NOW,
          (int64_t)(0.05 * NSEC_PER_SEC)),
      dispatch_get_main_queue(),
      ^{

        UIViewController *vc =
            weakSelf;

        if (!vc) {
          return;
        }

        rf_addSettingsButtonToView(
            vc.view,
            vc);
      });
}

%new
- (void)redditFilter_settingsButtonTapped:
    (UIButton *)sender {

  rf_log(@"RedditFilter Settings tapped via overlay button!");

  UIViewController *top =
      rf_topPresentableVC();

  if (top) {
    redditFilter_presentSettings(top);
  }
}

%end

// ============================================================================
// MARK: - LEGACY HOOKS
// ============================================================================
//
// IMPORTANT:
// These hooks intentionally do NOT use:
//     %group Legacy
//
// Therefore they belong to Logos' implicit _ungrouped group.
//
// There must be only ONE %init for _ungrouped at the bottom.
// ============================================================================

%hook Listing

- (void)fetchNextPage:
    (id (^)(NSArray *, id))completionHandler {

  id (^newCompletionHandler)(
      NSArray *,
      id) =
      ^(NSArray *objects, id unused) {

        NSArray *filtered =
            filteredObjects(objects);

        return completionHandler(
            filtered,
            unused);
      };

  return %orig(newCompletionHandler);
}

%end

%hook FeedNetworkSource

- (NSArray *)postsAndCommentsFromData:
    (id)data {

  // IMPORTANT:
  // Do not write:
  //
  // return filteredObjects(%orig);
  //
  // because Logos can generate a nested macro expression
  // that becomes difficult for the compiler to parse.

  NSArray *objects =
      %orig;

  return filteredObjects(objects);
}

%end

%hook PostDetailPresenter

- (BOOL)shouldFetchCommentAdPost {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterPromoted]) {

    return NO;
  }

  return %orig;
}

- (BOOL)shouldFetchAdditionalCommentAdPosts {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterPromoted]) {

    return NO;
  }

  return %orig;
}

%end

%hook Carousel

- (BOOL)isHiddenByUserWithAccountSettings:
    (id)accountSettings {

  BOOL filterRecommended =
      [NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterRecommended];

  if (filterRecommended) {

    NSString *analyticType =
        self.analyticType;

    if ([analyticType
            containsString:@"recommended"] ||
        [analyticType
            containsString:@"similar"] ||
        [analyticType
            containsString:@"popular"]) {

      return YES;
    }
  }

  return %orig;
}

%end

%hook QuickActionViewModel

- (void)fetchActions {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterRecommended]) {

    return;
  }

  %orig;
}

%end

%hook Post

- (NSArray *)awardingTotals {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAwards]) {

    return nil;
  }

  return %orig;
}

- (NSUInteger)totalAwardsReceived {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAwards]) {

    return 0;
  }

  return %orig;
}

- (BOOL)canAward {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAwards]) {

    return NO;
  }

  return %orig;
}

- (BOOL)isScoreHidden {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterScores]) {

    return YES;
  }

  return %orig;
}

%end

%hook Comment

- (NSArray *)awardingTotals {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAwards]) {

    return nil;
  }

  return %orig;
}

- (NSUInteger)totalAwardsReceived {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAwards]) {

    return 0;
  }

  return %orig;
}

- (BOOL)canAward {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAwards]) {

    return NO;
  }

  return %orig;
}

- (BOOL)shouldHighlightForHighAward {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAwards]) {

    return NO;
  }

  return %orig;
}

- (BOOL)isScoreHidden {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterScores]) {

    return YES;
  }

  return %orig;
}

- (BOOL)shouldAutoCollapse {

  if ([NSUserDefaults.standardUserDefaults
          boolForKey:kRedditFilterAutoCollapseAutoMod] &&
      [((Comment *)self).authorPk
          isEqualToString:@"t2_6l4z3"]) {

    return YES;
  }

  return %orig;
}

%end

%hook ToggleImageTableViewCell

- (void)updateConstraints {

  %orig;

  UIStackView *horizontalStackView =
      [self respondsToSelector:
                 @selector(imageLabelView)]
          ? [self imageLabelView].horizontalStackView
          : object_getIvar(
                self,
                class_getInstanceVariable(
                    object_getClass(self),
                    "horizontalStackView"));

  UILabel *detailLabel =
      [self respondsToSelector:
                 @selector(imageLabelView)]
          ? [self imageLabelView].detailLabel
          : [self detailLabel];

  if (!horizontalStackView ||
      !detailLabel) {

    return;
  }

  if (!detailLabel.text) {
    return;
  }

  UIView *contentView =
      [self contentView];

  // IMPORTANT:
  // Correctly closed NSArray literal.
  // This fixes:
  //
  // Tweak.xm:1443:6: error: expected ']'

  [contentView addConstraints:@[
    [NSLayoutConstraint
        constraintWithItem:detailLabel
                 attribute:NSLayoutAttributeHeight
                 relatedBy:NSLayoutRelationEqual
                    toItem:horizontalStackView
                 attribute:NSLayoutAttributeHeight
                multiplier:0.33
                  constant:0],

    [NSLayoutConstraint
        constraintWithItem:horizontalStackView
                 attribute:NSLayoutAttributeHeight
                 relatedBy:NSLayoutRelationEqual
                    toItem:contentView
                 attribute:NSLayoutAttributeHeight
                multiplier:1.0
                  constant:0],

    [NSLayoutConstraint
        constraintWithItem:horizontalStackView
                 attribute:NSLayoutAttributeCenterY
                 relatedBy:NSLayoutRelationEqual
                    toItem:contentView
                 attribute:NSLayoutAttributeCenterY
                multiplier:1.0
                  constant:0]
  ]];
}

%end

// ============================================================================
// MARK: - CONSTRUCTOR
// ============================================================================

%ctor {

  NSLog(@"[RedditFilter] Initializing - injecting entry into profile drawer menu");

  // --------------------------------------------------------------------------
  // Asset bundles
  // --------------------------------------------------------------------------

  assetBundles =
      [NSMutableArray array];

  assetCatalogs =
      [NSMutableArray array];

  [assetBundles
      addObject:NSBundle.mainBundle];

  for (NSString *file in
       [NSFileManager.defaultManager
           contentsOfDirectoryAtPath:
               NSBundle.mainBundle.bundlePath
                              error:nil]) {

    if (![file hasSuffix:@"bundle"]) {
      continue;
    }

    NSString *resourceName =
        [file stringByDeletingPathExtension];

    NSString *bundlePath =
        [NSBundle.mainBundle
            pathForResource:resourceName
                     ofType:@"bundle"];

    NSBundle *bundle =
        [NSBundle bundleWithPath:bundlePath];

    if (bundle) {
      [assetBundles addObject:bundle];
    }
  }

  // --------------------------------------------------------------------------
  // Framework bundles
  // --------------------------------------------------------------------------

  NSString *frameworksPath =
      [NSBundle.mainBundle.bundlePath
          stringByAppendingPathComponent:
              @"Frameworks"];

  NSArray *frameworkFiles =
      [NSFileManager.defaultManager
          contentsOfDirectoryAtPath:
              frameworksPath
                             error:nil];

  for (NSString *file in frameworkFiles) {

    if (![file hasSuffix:@"framework"]) {
      continue;
    }

    NSString *frameworkName =
        [file stringByDeletingPathExtension];

    NSString *frameworkPath =
        [NSBundle.mainBundle
            pathForResource:frameworkName
                     ofType:@"framework"
                inDirectory:@"Frameworks"];

    if (!frameworkPath) {
      continue;
    }

    NSBundle *bundle =
        [NSBundle bundleWithPath:frameworkPath];

    if (bundle) {
      [assetBundles addObject:bundle];
    }

    NSArray *frameworkContents =
        [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:
                frameworkPath
                               error:nil];

    for (NSString *nestedFile
         in frameworkContents) {

      if (![nestedFile hasSuffix:@"bundle"]) {
        continue;
      }

      NSString *nestedPath =
          [frameworkPath
              stringByAppendingPathComponent:
                  nestedFile];

      NSBundle *nestedBundle =
          [NSBundle bundleWithPath:nestedPath];

      if (nestedBundle) {
        [assetBundles addObject:nestedBundle];
      }
    }
  }

  // --------------------------------------------------------------------------
  // Asset catalogs
  // --------------------------------------------------------------------------

  for (NSBundle *bundle in assetBundles) {

    NSError *error = nil;

    CUICatalog *catalog =
        [[%c(CUICatalog) alloc]
            initWithName:@"Assets"
            fromBundle:bundle
            error:&error];

    if (!error &&
        catalog) {

      [assetCatalogs addObject:catalog];
    }
  }

  // --------------------------------------------------------------------------
  // Default preferences
  // --------------------------------------------------------------------------

  NSUserDefaults *defaults =
      NSUserDefaults.standardUserDefaults;

  if (![defaults
          objectForKey:kRedditFilterPromoted]) {

    [defaults setBool:YES
               forKey:kRedditFilterPromoted];
  }

  if (![defaults
          objectForKey:kRedditFilterRecommended]) {

    [defaults setBool:NO
               forKey:kRedditFilterRecommended];
  }

  if (![defaults
          objectForKey:kRedditFilterNSFW]) {

    [defaults setBool:NO
               forKey:kRedditFilterNSFW];
  }

  if (![defaults
          objectForKey:kRedditFilterAwards]) {

    [defaults setBool:NO
               forKey:kRedditFilterAwards];
  }

  if (![defaults
          objectForKey:kRedditFilterScores]) {

    [defaults setBool:NO
               forKey:kRedditFilterScores];
  }

  if (![defaults
          objectForKey:kRedditFilterAutoCollapseAutoMod]) {

    [defaults setBool:NO
               forKey:kRedditFilterAutoCollapseAutoMod];
  }

  NSLog(@"[RedditFilter] Loaded - open the profile drawer to find 'RedditFilter Settings'");

  // ==========================================================================
  // IMPORTANT LOGOS INITIALIZATION
  // ==========================================================================
  //
  // There is intentionally ONLY ONE %init here.
  //
  // DO NOT add:
  //
  //     %init;
  //
  // before this.
  //
  // All hooks above are in Logos' implicit _ungrouped group.
  //
  // The previous error:
  //
  //     re-%init of %group _ungrouped
  //
  // was caused by initializing this group twice.
  //
  // ==========================================================================

  %init(
      Comment =
          CoreClass(@"Comment"),

      Post =
          CoreClass(@"Post"),

      QuickActionViewModel =
          CoreClass(@"QuickActionViewModel"),

      ToggleImageTableViewCell =
          CoreClass(@"ToggleImageTableViewCell")
  );
}
