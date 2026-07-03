/*
 * ApolloGalleryMode.xm
 * Apollo-Reborn — Gallery Layout Mode
 *
 * Adds a third "Gallery" option to the Large / Compact layout switcher that
 * already exists in Apollo's subreddit/feed view.
 *
 * What this does:
 *   - Hooks the layout-picker UI to inject a "Gallery" segment/button
 *   - When Gallery is active: replaces the feed table/collection with a
 *     UICollectionView showing a 2-3 column image-thumbnail grid
 *   - Tapping a thumbnail opens ARSwipeGalleryViewController, a
 *     UIPageViewController that lets the user swipe through all media
 *     posts in the current feed
 *   - Tapping opens Apollo's NATIVE media viewer (no custom player)
 *   - Large and Compact modes are completely untouched
 *
 * Hook surface:
 *   APHFeedViewController          — the main feed/subreddit VC
 *   APHLayoutSwitcherView (or the
 *     UISegmentedControl it contains) — the Large/Compact picker
 *
 * All private-API access is via safe KVC + @try/@catch so the code
 * degrades gracefully on future Apollo builds.
 *
 * Build: Theos / Logos (rootless, sideload target)
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// MARK: – Shared preference key
// ---------------------------------------------------------------------------

static NSString *const kGalleryModeActiveKey   = @"ARGalleryModeActive";
// Per-feed persistence: "ARGalleryMode_<subreddit>"
static NSString *galleryModeKeyForFeed(NSString *feed) {
    return [NSString stringWithFormat:@"ARGalleryMode_%@", feed ?: @"home"];
}

// ---------------------------------------------------------------------------
// MARK: – ARThumbnailItem  (one cell's data)
// ---------------------------------------------------------------------------

@interface ARThumbnailItem : NSObject
@property (nonatomic, strong) NSURL     *thumbnailURL;  // best available preview
@property (nonatomic, strong) NSURL     *mediaURL;      // full-res / video URL
@property (nonatomic, copy)   NSString  *postTitle;
@property (nonatomic, strong) id         rawPost;       // the original RDKLink
@property (nonatomic, assign) NSInteger  feedIndex;     // index in full feed array
@end
@implementation ARThumbnailItem @end

// ---------------------------------------------------------------------------
// MARK: – ARMediaItemExtractor
// ---------------------------------------------------------------------------

@interface ARMediaItemExtractor : NSObject
+ (nullable ARThumbnailItem *)itemFromPost:(id)post feedIndex:(NSInteger)idx;
+ (NSArray<ARThumbnailItem *> *)mediaItemsFromPosts:(NSArray *)posts;
@end

@implementation ARMediaItemExtractor

+ (nullable ARThumbnailItem *)itemFromPost:(id)post feedIndex:(NSInteger)idx {
    if (!post) return nil;

    NSURL    *mediaURL  = nil;
    NSURL    *thumbURL  = nil;
    NSString *linkType  = nil;
    NSString *title     = nil;

    @try {
        if ([post respondsToSelector:NSSelectorFromString(@"URL")])
            mediaURL = [post valueForKey:@"URL"];

        if ([post respondsToSelector:NSSelectorFromString(@"linkType")])
            linkType = [post valueForKey:@"linkType"];

        if ([post respondsToSelector:NSSelectorFromString(@"title")])
            title = [post valueForKey:@"title"];

        // Apollo stores preview images as array of URLs, smallest → largest
        if ([post respondsToSelector:NSSelectorFromString(@"previewImageURLs")]) {
            NSArray *previews = [post valueForKey:@"previewImageURLs"];
            // We want a medium-size thumbnail; index 1 or 2 is usually ~320px
            if (previews.count >= 3)
                thumbURL = previews[2];
            else if (previews.count >= 2)
                thumbURL = previews[1];
            else
                thumbURL = previews.firstObject;
        }

        // Fallback: some posts expose a single thumbnailURL property
        if (!thumbURL && [post respondsToSelector:NSSelectorFromString(@"thumbnailURL")])
            thumbURL = [post valueForKey:@"thumbnailURL"];
    } @catch (...) {}

    // Only include image/gif/video posts; skip text & link-only posts
    if (!mediaURL && !thumbURL) return nil;
    NSString *lt = [linkType lowercaseString];
    BOOL isMedia = [lt containsString:@"image"] ||
                   [lt containsString:@"img"]   ||
                   [lt containsString:@"gif"]   ||
                   [lt containsString:@"video"] ||
                   [lt containsString:@"vid"];
    if (!isMedia) {
        // Fallback: check URL extension
        NSString *ext = mediaURL.pathExtension.lowercaseString;
        isMedia = [@[@"jpg",@"jpeg",@"png",@"webp",@"gif",
                     @"mp4",@"mov",@"m3u8"] containsObject:ext];
    }
    if (!isMedia) return nil;

    ARThumbnailItem *item = [[ARThumbnailItem alloc] init];
    item.thumbnailURL = thumbURL ?: mediaURL;
    item.mediaURL     = mediaURL;
    item.postTitle    = title;
    item.rawPost      = post;
    item.feedIndex    = idx;
    return item;
}

+ (NSArray<ARThumbnailItem *> *)mediaItemsFromPosts:(NSArray *)posts {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:posts.count];
    for (NSInteger i = 0; i < (NSInteger)posts.count; i++) {
        ARThumbnailItem *item = [self itemFromPost:posts[i] feedIndex:i];
        if (item) [result addObject:item];
    }
    return result;
}

@end

// ---------------------------------------------------------------------------
// MARK: – ARGridThumbnailCell
// ---------------------------------------------------------------------------

@interface ARGridThumbnailCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIView      *videoOverlay;  // small play badge
@property (nonatomic, strong) UIImageView *playIcon;
- (void)configureWithItem:(ARThumbnailItem *)item;
- (void)cancelLoad;
@end

static NSString *const kThumbnailCellID = @"ARGridThumbnailCell";

// Simple in-memory URL→UIImage cache (cleared on memory warning)
static NSCache<NSURL *, UIImage *> *gImageCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 200;
    });
    return cache;
}

@implementation ARGridThumbnailCell {
    NSURLSessionDataTask *_loadTask;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];

    self.imageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
    self.imageView.contentMode = UIViewContentModeScaleAspectFill;
    self.imageView.clipsToBounds = YES;
    self.imageView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:self.imageView];

    // Video badge (bottom-left triangle)
    self.videoOverlay = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
    self.videoOverlay.hidden = YES;
    [self.contentView addSubview:self.videoOverlay];

    self.playIcon = [[UIImageView alloc] initWithFrame:CGRectMake(4, 4, 20, 20)];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14
                                                        weight:UIImageSymbolWeightBold];
    self.playIcon.image =
        [[UIImage systemImageNamed:@"play.fill"
                 withConfiguration:cfg]
         imageWithTintColor:UIColor.whiteColor
              renderingMode:UIImageRenderingModeAlwaysOriginal];
    [self.videoOverlay addSubview:self.playIcon];

    return self;
}

- (void)configureWithItem:(ARThumbnailItem *)item {
    [self cancelLoad];
    self.imageView.image = nil;

    // Detect video for badge
    NSString *ext = item.mediaURL.pathExtension.lowercaseString;
    BOOL isVideo = [@[@"mp4",@"mov",@"m3u8"] containsObject:ext] ||
                   [item.rawPost respondsToSelector:NSSelectorFromString(@"linkType")] &&
                   [[[item.rawPost valueForKey:@"linkType"] lowercaseString]
                    containsString:@"video"];
    self.videoOverlay.hidden = !isVideo;

    if (!item.thumbnailURL) return;

    // Check cache first
    UIImage *cached = [gImageCache() objectForKey:item.thumbnailURL];
    if (cached) { self.imageView.image = cached; return; }

    __weak typeof(self) weakSelf = self;
    NSURL *url = item.thumbnailURL;
    _loadTask = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        [gImageCache() setObject:img forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.imageView.image == nil) {  // don't overwrite a recycled cell
                weakSelf.imageView.image = img;
            }
        });
    }];
    [_loadTask resume];
}

- (void)cancelLoad {
    [_loadTask cancel];
    _loadTask = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self cancelLoad];
    self.imageView.image = nil;
    self.videoOverlay.hidden = YES;
}

@end

// ---------------------------------------------------------------------------
// MARK: – ARSwipeGalleryViewController
//         (UIPageViewController to swipe between thumbnail items)
//
//  Each page shows the thumbnail full-screen.
//  Tapping opens Apollo's NATIVE media viewer via the rawPost object.
// ---------------------------------------------------------------------------

@interface ARSwipeGalleryPageVC : UIViewController
@property (nonatomic, strong) ARThumbnailItem *item;
@property (nonatomic, assign) NSInteger        pageIndex;
@property (nonatomic, copy)   void (^onTapNativeOpen)(ARThumbnailItem *);
+ (instancetype)pageWithItem:(ARThumbnailItem *)item
                       index:(NSInteger)index
             nativeOpenBlock:(void(^)(ARThumbnailItem *))block;
@end

@implementation ARSwipeGalleryPageVC

+ (instancetype)pageWithItem:(ARThumbnailItem *)item
                       index:(NSInteger)index
             nativeOpenBlock:(void(^)(ARThumbnailItem *))block {
    ARSwipeGalleryPageVC *vc = [[self alloc] init];
    vc.item            = item;
    vc.pageIndex       = index;
    vc.onTapNativeOpen = block;
    return vc;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    // Full-screen thumbnail image
    UIImageView *iv = [[UIImageView alloc] initWithFrame:self.view.bounds];
    iv.contentMode  = UIViewContentModeScaleAspectFit;
    iv.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];

    UIImage *cached = [gImageCache() objectForKey:self.item.thumbnailURL];
    if (cached) {
        iv.image = cached;
    } else if (self.item.thumbnailURL) {
        __weak UIImageView *weakIV = iv;
        [[NSURLSession sharedSession]
            dataTaskWithURL:self.item.thumbnailURL
          completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            if (!d) return;
            UIImage *img = [UIImage imageWithData:d];
            if (!img) return;
            [gImageCache() setObject:img forKey:self.item.thumbnailURL];
            dispatch_async(dispatch_get_main_queue(), ^{ weakIV.image = img; });
        }].resume;  // fire and forget
        // Note: [task resume] pattern; using .resume shorthand here
    }

    // Title bar at bottom
    UILabel *title = [[UILabel alloc] init];
    title.text          = self.item.postTitle;
    title.textColor     = UIColor.whiteColor;
    title.font          = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    title.numberOfLines = 2;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.shadowColor   = [UIColor colorWithWhite:0 alpha:0.6];
    title.shadowOffset  = CGSizeMake(0, 1);

    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];
    [bar addSubview:title];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:70],
        [title.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [title.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    // "Open in Apollo" button (top-right) → triggers native media viewer
    UIButton *openBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:20
                                                        weight:UIImageSymbolWeightMedium];
    UIImage *chevron = [UIImage systemImageNamed:@"arrow.up.right.square"
                              withConfiguration:cfg];
    [openBtn setImage:chevron forState:UIControlStateNormal];
    openBtn.tintColor = UIColor.whiteColor;
    openBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:openBtn];
    [openBtn addTarget:self
                action:@selector(openNative)
      forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [openBtn.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [openBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [openBtn.widthAnchor constraintEqualToConstant:44],
        [openBtn.heightAnchor constraintEqualToConstant:44],
    ]];

    // Tap the image itself also opens native
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(openNative)];
    [iv addSubview:[[UIView alloc] init]];  // needed to enable tap on UIImageView
    iv.userInteractionEnabled = YES;
    [iv addGestureRecognizer:tap];
}

- (void)openNative {
    if (self.onTapNativeOpen) self.onTapNativeOpen(self.item);
}

@end

// ---------------------------------------------------------------------------

@interface ARSwipeGalleryViewController : UIViewController
                                            <UIPageViewControllerDataSource,
                                             UIPageViewControllerDelegate>
@property (nonatomic, strong) NSArray<ARThumbnailItem *> *items;
@property (nonatomic, assign) NSInteger                   startIndex;
@property (nonatomic, copy)   void (^nativeOpenBlock)(ARThumbnailItem *);

@property (nonatomic, strong) UIPageViewController *pageVC;
@property (nonatomic, strong) UILabel              *counterLabel;
@property (nonatomic, assign) NSInteger             currentIndex;

+ (instancetype)galleryWithItems:(NSArray<ARThumbnailItem *> *)items
                      startIndex:(NSInteger)startIndex
                 nativeOpenBlock:(void(^)(ARThumbnailItem *))block;
@end

@implementation ARSwipeGalleryViewController

+ (instancetype)galleryWithItems:(NSArray<ARThumbnailItem *> *)items
                      startIndex:(NSInteger)startIndex
                 nativeOpenBlock:(void(^)(ARThumbnailItem *))block {
    ARSwipeGalleryViewController *vc = [[self alloc] init];
    vc.items           = items;
    vc.startIndex      = startIndex;
    vc.currentIndex    = startIndex;
    vc.nativeOpenBlock = block;
    return vc;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.pageVC = [[UIPageViewController alloc]
        initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll
          navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                        options:nil];
    self.pageVC.dataSource = self;
    self.pageVC.delegate   = self;

    [self addChildViewController:self.pageVC];
    self.pageVC.view.frame = self.view.bounds;
    self.pageVC.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pageVC.view];
    [self.pageVC didMoveToParentViewController:self];

    [self.pageVC setViewControllers:@[[self pageVCAtIndex:self.startIndex]]
                          direction:UIPageViewControllerNavigationDirectionForward
                           animated:NO
                         completion:nil];

    // Close button (top-left)
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18
                                                        weight:UIImageSymbolWeightMedium];
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:cfg]
              forState:UIControlStateNormal];
    closeBtn.tintColor = UIColor.whiteColor;
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:closeBtn];
    [closeBtn addTarget:self action:@selector(dismiss:)
       forControlEvents:UIControlEventTouchUpInside];

    // Counter "3 / 12" (top-centre)
    self.counterLabel = [[UILabel alloc] init];
    self.counterLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    self.counterLabel.font      = [UIFont systemFontOfSize:14];
    self.counterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.counterLabel];
    [self updateCounter];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [closeBtn.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [closeBtn.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [closeBtn.widthAnchor constraintEqualToConstant:44],
        [closeBtn.heightAnchor constraintEqualToConstant:44],
        [self.counterLabel.centerYAnchor constraintEqualToAnchor:closeBtn.centerYAnchor],
        [self.counterLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];

    // Swipe-down to dismiss
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismiss:)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipe];
}

- (ARSwipeGalleryPageVC *)pageVCAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) return nil;
    __weak typeof(self) weakSelf = self;
    return [ARSwipeGalleryPageVC pageWithItem:self.items[index]
                                        index:index
                              nativeOpenBlock:^(ARThumbnailItem *item) {
        [weakSelf openNativeForItem:item];
    }];
}

- (void)openNativeForItem:(ARThumbnailItem *)item {
    // Dismiss the gallery first, then tell the feed VC to open its native viewer
    [self dismissViewControllerAnimated:YES completion:^{
        // Post a notification that ApolloGalleryGridVC will observe
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"AROpenNativeMediaForPost"
                          object:item.rawPost];
    }];
}

- (void)updateCounter {
    if (self.items.count > 1) {
        self.counterLabel.text =
            [NSString stringWithFormat:@"%ld / %ld",
             (long)(self.currentIndex + 1), (long)self.items.count];
    } else {
        self.counterLabel.text = @"";
    }
}

// UIPageViewControllerDataSource
- (UIViewController *)pageViewController:(UIPageViewController *)pvc
      viewControllerBeforeViewController:(UIViewController *)vc {
    return [self pageVCAtIndex:((ARSwipeGalleryPageVC *)vc).pageIndex - 1];
}
- (UIViewController *)pageViewController:(UIPageViewController *)pvc
       viewControllerAfterViewController:(UIViewController *)vc {
    return [self pageVCAtIndex:((ARSwipeGalleryPageVC *)vc).pageIndex + 1];
}

// UIPageViewControllerDelegate
- (void)pageViewController:(UIPageViewController *)pvc
        didFinishAnimating:(BOOL)finished
   previousViewControllers:(NSArray *)previous
       transitionCompleted:(BOOL)completed {
    if (!completed) return;
    self.currentIndex = ((ARSwipeGalleryPageVC *)pvc.viewControllers.firstObject).pageIndex;
    [self updateCounter];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }

@end

// ---------------------------------------------------------------------------
// MARK: – ARGalleryGridViewController
//         The UICollectionViewController that is the "Gallery" layout
// ---------------------------------------------------------------------------

@interface ARGalleryGridViewController : UICollectionViewController
@property (nonatomic, strong) NSArray<ARThumbnailItem *> *items;
// Callback: when the user taps a cell → caller presents the swipe gallery
@property (nonatomic, copy) void (^onSelectItem)(ARThumbnailItem *item,
                                                  NSArray<ARThumbnailItem *> *allItems);
+ (instancetype)gridWithItems:(NSArray<ARThumbnailItem *> *)items
                 onSelectItem:(void(^)(ARThumbnailItem *, NSArray<ARThumbnailItem *> *))block;
@end

@implementation ARGalleryGridViewController

+ (instancetype)gridWithItems:(NSArray<ARThumbnailItem *> *)items
                 onSelectItem:(void(^)(ARThumbnailItem *, NSArray<ARThumbnailItem *> *))block {
    // 2-column flow layout with 1pt gaps
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 1;
    layout.minimumLineSpacing      = 1;
    layout.sectionInset            = UIEdgeInsetsZero;

    ARGalleryGridViewController *vc =
        [[self alloc] initWithCollectionViewLayout:layout];
    vc.items        = items;
    vc.onSelectItem = block;
    return vc;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    [self.collectionView registerClass:[ARGridThumbnailCell class]
            forCellWithReuseIdentifier:kThumbnailCellID];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Recalculate cell size: 3 columns with 1pt gaps
    UICollectionViewFlowLayout *layout =
        (UICollectionViewFlowLayout *)self.collectionViewLayout;
    CGFloat width = self.collectionView.bounds.size.width;
    CGFloat cellSize = floor((width - 2) / 3.0);  // 2 gaps between 3 columns
    layout.itemSize = CGSizeMake(cellSize, cellSize);  // square cells
}

// UICollectionViewDataSource
- (NSInteger)collectionView:(UICollectionView *)cv
     numberOfItemsInSection:(NSInteger)section {
    return self.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    ARGridThumbnailCell *cell =
        [cv dequeueReusableCellWithReuseIdentifier:kThumbnailCellID
                                      forIndexPath:ip];
    [cell configureWithItem:self.items[ip.item]];
    return cell;
}

// UICollectionViewDelegate
- (void)collectionView:(UICollectionView *)cv
didSelectItemAtIndexPath:(NSIndexPath *)ip {
    if (self.onSelectItem)
        self.onSelectItem(self.items[ip.item], self.items);
}

@end

// ---------------------------------------------------------------------------
// MARK: – Logos Hooks into APHFeedViewController
// ---------------------------------------------------------------------------

/*
 * Apollo's subreddit/home-feed VC (approximate class name: APHFeedViewController
 * or APHSubredditViewController) contains:
 *   - A UITableView or UICollectionView displaying posts
 *   - A layout picker (UISegmentedControl or custom buttons) for Large/Compact
 *
 * Strategy:
 *   1. Hook -viewDidLoad to inject a "Gallery" button next to Large/Compact
 *   2. When Gallery is selected, hide Apollo's native feed view and show our grid
 *   3. When Large/Compact is re-selected, remove our grid and show Apollo's view
 *   4. All native Apollo paths for Large/Compact are 100% untouched
 */

// Associated object keys
static const char kGalleryGridVCKey    = 0;
static const char kGalleryButtonKey    = 0;
static const char kGalleryModeOnKey    = 0;
static const char kGalleryContainerKey = 0;
static const char kNativeListViewKey   = 0;

// ---------------------------------------------------------------------------
%hook APHFeedViewController

// ----- viewDidLoad: inject Gallery button into the layout switcher ----------
- (void)viewDidLoad {
    %orig;
    [self ar_injectGalleryButton];
}

// ----- Observe Apollo's own layout changes and deactivate gallery if needed -
- (void)setLayoutMode:(NSInteger)mode {
    %orig;
    if ([self ar_galleryModeIsOn]) {
        [self ar_deactivateGallery];
    }
}

// ===========================================================================
// %new methods
// ===========================================================================

%new
- (void)ar_injectGalleryButton {
    // Find the layout picker UISegmentedControl inside our view hierarchy
    UISegmentedControl *picker = [self ar_findLayoutPicker];
    if (!picker) return;

    // Add "Gallery" as a third segment if not already there
    if (picker.numberOfSegments < 3) {
        [picker insertSegmentWithTitle:@"Gallery"
                               atIndex:picker.numberOfSegments
                              animated:NO];
        [picker addTarget:self
                   action:@selector(ar_layoutPickerChanged:)
         forControlEvents:UIControlEventValueChanged];
    }

    objc_setAssociatedObject(self, &kGalleryButtonKey,
                             picker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (nullable UISegmentedControl *)ar_findLayoutPicker {
    // Walk the view hierarchy looking for a UISegmentedControl with 2 segments
    // (Apollo's Large/Compact picker is the only one in the feed VC's view)
    return [self ar_searchForSegmentedControlIn:self.view];
}

%new
- (nullable UISegmentedControl *)ar_searchForSegmentedControlIn:(UIView *)view {
    if ([view isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *sc = (UISegmentedControl *)view;
        if (sc.numberOfSegments == 2) return sc;
    }
    for (UIView *sub in view.subviews) {
        UISegmentedControl *found = [self ar_searchForSegmentedControlIn:sub];
        if (found) return found;
    }
    return nil;
}

%new
- (void)ar_layoutPickerChanged:(UISegmentedControl *)picker {
    if (picker.selectedSegmentIndex == 2) {
        // "Gallery" tapped
        [self ar_activateGallery];
    } else {
        // Large or Compact tapped — remove gallery if it was on
        if ([self ar_galleryModeIsOn]) {
            [self ar_deactivateGallery];
        }
        // Let Apollo handle the rest naturally (the segmented control already
        // fires Apollo's own handler; we just clean up our additions)
    }
}

%new
- (BOOL)ar_galleryModeIsOn {
    NSNumber *n = objc_getAssociatedObject(self, &kGalleryModeOnKey);
    return n.boolValue;
}

%new
- (void)ar_setGalleryModeOn:(BOOL)on {
    objc_setAssociatedObject(self, &kGalleryModeOnKey,
                             @(on), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)ar_activateGallery {
    [self ar_setGalleryModeOn:YES];

    // 1. Gather posts from the feed's data model
    NSArray *posts = nil;
    @try {
        if ([self respondsToSelector:NSSelectorFromString(@"links")])
            posts = [self valueForKey:@"links"];
        else if ([self respondsToSelector:NSSelectorFromString(@"posts")])
            posts = [self valueForKey:@"posts"];
    } @catch (...) {}

    NSArray<ARThumbnailItem *> *items =
        [ARMediaItemExtractor mediaItemsFromPosts:posts ?: @[]];

    // 2. Hide Apollo's native list/table (don't remove — we'll un-hide it later)
    UIView *nativeList = [self ar_findFeedListView];
    if (nativeList) {
        nativeList.hidden = YES;
        objc_setAssociatedObject(self, &kNativeListViewKey,
                                 nativeList, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 3. Build and embed the grid VC
    __weak typeof(self) weakSelf = self;
    ARGalleryGridViewController *grid =
        [ARGalleryGridViewController
         gridWithItems:items
          onSelectItem:^(ARThumbnailItem *item, NSArray<ARThumbnailItem *> *all) {
            [weakSelf ar_presentSwipeGalleryWithItems:all startItem:item];
        }];

    // Container view that fills below the navigation bar / layout picker
    UIView *container = [[UIView alloc] initWithFrame:self.view.bounds];
    container.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    objc_setAssociatedObject(self, &kGalleryContainerKey,
                             container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [self addChildViewController:grid];
    grid.view.frame = container.bounds;
    grid.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:grid.view];
    [grid didMoveToParentViewController:self];

    [self.view addSubview:container];
    objc_setAssociatedObject(self, &kGalleryGridVCKey,
                             grid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 4. Observe native-open notification (from swipe gallery's "open in Apollo" button)
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(ar_handleNativeOpenNotification:)
               name:@"AROpenNativeMediaForPost"
             object:nil];
}

%new
- (void)ar_deactivateGallery {
    [self ar_setGalleryModeOn:NO];

    [[NSNotificationCenter defaultCenter]
        removeObserver:self name:@"AROpenNativeMediaForPost" object:nil];

    // Remove grid VC
    ARGalleryGridViewController *grid =
        objc_getAssociatedObject(self, &kGalleryGridVCKey);
    [grid willMoveToParentViewController:nil];
    [grid.view removeFromSuperview];
    [grid removeFromParentViewController];
    objc_setAssociatedObject(self, &kGalleryGridVCKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Remove container
    UIView *container = objc_getAssociatedObject(self, &kGalleryContainerKey);
    [container removeFromSuperview];
    objc_setAssociatedObject(self, &kGalleryContainerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Restore Apollo's native list
    UIView *nativeList = objc_getAssociatedObject(self, &kNativeListViewKey);
    nativeList.hidden = NO;
    objc_setAssociatedObject(self, &kNativeListViewKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%new
- (void)ar_presentSwipeGalleryWithItems:(NSArray<ARThumbnailItem *> *)items
                              startItem:(ARThumbnailItem *)startItem {
    NSInteger startIndex = [items indexOfObject:startItem];
    if (startIndex == NSNotFound) startIndex = 0;

    __weak typeof(self) weakSelf = self;
    ARSwipeGalleryViewController *gallery =
        [ARSwipeGalleryViewController
         galleryWithItems:items
               startIndex:startIndex
          nativeOpenBlock:^(ARThumbnailItem *item) {
            // Called when user taps the ↗ button on a page: open Apollo's
            // native viewer for that post
            [weakSelf ar_openNativeViewerForPost:item.rawPost];
        }];

    gallery.modalPresentationStyle = UIModalPresentationOverFullScreen;
    gallery.modalTransitionStyle   = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:gallery animated:YES completion:nil];
}

%new
- (void)ar_handleNativeOpenNotification:(NSNotification *)note {
    id post = note.object;
    if (post) [self ar_openNativeViewerForPost:post];
}

%new
- (void)ar_openNativeViewerForPost:(id)post {
    /*
     * Trigger Apollo's own media viewer for this post object.
     * Apollo uses a coordinator / router pattern; the exact selector varies
     * between builds but these are the two most common patterns observed:
     *
     *   - [self openMediaViewerForLink:post]
     *   - [self.coordinator openMediaViewerForLink:post animated:YES]
     *
     * We try them in order, falling back to simply selecting the post in
     * the table view which causes Apollo to handle it normally.
     */
    SEL openSel = NSSelectorFromString(@"openMediaViewerForLink:");
    SEL coordSel = NSSelectorFromString(@"coordinator");

    if ([self respondsToSelector:openSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:openSel withObject:post];
#pragma clang diagnostic pop
        return;
    }

    @try {
        id coordinator = [self valueForKey:@"coordinator"];
        if (coordinator && [coordinator respondsToSelector:openSel]) {
            [coordinator performSelector:openSel withObject:post];
            return;
        }
    } @catch (...) {}

    // Last resort: find the post's row in Apollo's table and simulate a tap
    @try {
        UITableView *tv = [self ar_findFeedTableView];
        NSArray *posts = nil;
        if ([self respondsToSelector:NSSelectorFromString(@"links")])
            posts = [self valueForKey:@"links"];
        else if ([self respondsToSelector:NSSelectorFromString(@"posts")])
            posts = [self valueForKey:@"posts"];

        NSInteger idx = [posts indexOfObject:post];
        if (idx != NSNotFound && tv) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:idx inSection:0];
            [tv selectRowAtIndexPath:ip
                            animated:NO
                      scrollPosition:UITableViewScrollPositionNone];
            [tv.delegate tableView:tv didSelectRowAtIndexPath:ip];
        }
    } @catch (...) {}
}

%new
- (nullable UIView *)ar_findFeedListView {
    // Apollo's feed is usually a UITableView or UICollectionView directly
    // in self.view or one level below
    for (UIView *sub in self.view.subviews) {
        if ([sub isKindOfClass:[UITableView class]] ||
            [sub isKindOfClass:[UICollectionView class]]) {
            return sub;
        }
    }
    return nil;
}

%new
- (nullable UITableView *)ar_findFeedTableView {
    UIView *v = [self ar_findFeedListView];
    return [v isKindOfClass:[UITableView class]] ? (UITableView *)v : nil;
}

%end

// ---------------------------------------------------------------------------
// Also hook APHSubredditViewController — Apollo sometimes uses a separate
// class for subreddit feeds vs the home feed.  Same treatment.
// ---------------------------------------------------------------------------
%hook APHSubredditViewController

- (void)viewDidLoad {
    %orig;
    [self ar_injectGalleryButton];
}

- (void)setLayoutMode:(NSInteger)mode {
    %orig;
    if ([self ar_galleryModeIsOn]) {
        [self ar_deactivateGallery];
    }
}

%end

// ---------------------------------------------------------------------------
%ctor {
    %init;
}
