#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// Контроллер карточек в переключателе приложений (SpringBoard).
@interface SBFluidSwitcherViewController : UIViewController
@property (nonatomic, readonly) NSArray *appLayouts;
- (id)_itemContainerForAppLayoutIfExists:(id)layout;
- (void)killContainer:(id)container forReason:(NSInteger)reason;
- (void)qca_closeAll;
@end

// Главный контроллер переключателя: умеет удалять карточку целиком.
@interface SBMainSwitcherViewController : UIViewController
+ (instancetype)sharedInstance;
- (void)_deleteAppLayout:(id)layout forReason:(NSInteger)reason;
@end

enum { kButtonTag = 0x0C10A11 };

static __weak SBFluidSwitcherViewController *gVC;
static NSTimer *gTimer;

#pragma mark - Определяем, открыт ли переключатель

// Карточки переключателя. Когда вы внутри приложения или на домашнем экране,
// «карточка» занимает весь экран (масштаб 1). В переключателе все карточки
// уменьшены (масштаб около 0.5-0.7). По этому и узнаём, открыт ли переключатель.

static void ScanContainers(UIView *v, NSMutableArray *out, int depth) {
    if (depth > 5) return;
    for (UIView *s in v.subviews) {
        if ([NSStringFromClass([s class]) containsString:@"ItemContainer"]) {
            [out addObject:s];
            continue;
        }
        ScanContainers(s, out, depth + 1);
    }
}

static NSArray<UIView *> *SwitcherContainers(SBFluidSwitcherViewController *vc) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];

    if ([vc respondsToSelector:@selector(appLayouts)] &&
        [vc respondsToSelector:@selector(_itemContainerForAppLayoutIfExists:)]) {
        NSArray *layouts = [vc.appLayouts copy];
        if ([layouts isKindOfClass:[NSArray class]]) {
            for (id layout in layouts) {
                id c = [vc _itemContainerForAppLayoutIfExists:layout];
                if ([c isKindOfClass:[UIView class]]) [out addObject:c];
            }
        }
    }

    // Запасной путь: ищем карточки по имени класса.
    if (out.count == 0 && vc.isViewLoaded) {
        ScanContainers(vc.view, out, 0);
    }
    return out;
}

// Возвращает 0...1: насколько «открыт» переключатель (0 = закрыт, 1 = открыт).
static CGFloat SwitcherAmount(SBFluidSwitcherViewController *vc) {
    if (!vc.isViewLoaded) return 0;
    UIWindow *w = vc.view.window;
    if (!w || w.hidden || w.alpha < 0.05) return 0;

    CGRect screen = w.bounds;
    CGFloat screenArea = screen.size.width * screen.size.height;
    if (screenArea <= 0) return 0;

    CGFloat maxRatio = -1;
    for (UIView *c in SwitcherContainers(vc)) {
        if (!c.window) continue;

        BOOL hiddenInChain = NO;
        for (UIView *x = c; x; x = x.superview) {
            if (x.hidden || x.alpha < 0.05) { hiddenInChain = YES; break; }
        }
        if (hiddenInChain) continue;

        CGRect r = [c convertRect:c.bounds toView:nil];
        CGRect inter = CGRectIntersection(r, screen);
        if (CGRectIsNull(inter) || inter.size.width * inter.size.height < 0.15 * screenArea) continue;

        maxRatio = MAX(maxRatio, r.size.width / screen.size.width);
    }

    if (maxRatio < 0) return 0;                        // карточек на экране нет
    return MAX(0, MIN(1, (0.92 - maxRatio) / 0.2));    // 0.92 и выше = внутри приложения
}

#pragma mark - Кнопка

static NSString *ButtonTitle(void) {
    NSString *lang = [NSLocale preferredLanguages].firstObject ?: @"en";
    return [lang hasPrefix:@"ru"] ? @"Закрыть все" : @"Close All";
}

static UIButton *EnsureButton(SBFluidSwitcherViewController *vc) {
    UIView *host = vc.view;
    UIButton *b = (UIButton *)[host viewWithTag:kButtonTag];
    if (!b) {
        b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = kButtonTag;
        [b setTitle:ButtonTitle() forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.6] forState:UIControlStateHighlighted];
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
        b.contentEdgeInsets = UIEdgeInsetsMake(10, 22, 10, 22);
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.layer.masksToBounds = YES;
        b.alpha = 0.0;
        b.hidden = YES;
        [b addTarget:vc action:@selector(qca_closeAll) forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:b];
    }
    return b;
}

static void QCAUpdate(SBFluidSwitcherViewController *vc) {
    if (!vc || !vc.isViewLoaded) return;

    UIView *host = vc.view;
    UIButton *b = EnsureButton(vc);

    // Позиция: по центру внизу, над индикатором «домой».
    CGSize s = [b sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGFloat bottom = host.safeAreaInsets.bottom;
    b.frame = CGRectMake(round((host.bounds.size.width - s.width) / 2.0),
                         host.bounds.size.height - bottom - 28.0 - s.height,
                         s.width, s.height);
    b.layer.cornerRadius = s.height / 2.0;

    if (host.subviews.lastObject != b) {
        [host bringSubviewToFront:b];
    }

    // Кнопка плавно появляется, пока карточки уменьшаются, и исчезает, когда приложение открывается.
    CGFloat amount = SwitcherAmount(vc);
    b.hidden = amount < 0.02;
    b.alpha = amount;
    b.userInteractionEnabled = amount > 0.6;
}

static void StartTimer(void) {
    if (gTimer) return;
    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        SBFluidSwitcherViewController *vc = gVC;
        if (!vc) {
            [t invalidate];
            gTimer = nil;
            return;
        }
        QCAUpdate(vc);
    }];
}

#pragma mark - Хуки

%hook SBFluidSwitcherViewController

- (void)viewDidLayoutSubviews {
    %orig;
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        NSLog(@"[QuickCloseAll] SBFluidSwitcherViewController hook fired");
    }
    gVC = self;
    QCAUpdate(self);
    StartTimer();
}

%new
- (void)qca_closeAll {
    NSArray *layouts = [self.appLayouts copy];
    if (layouts.count == 0) return;

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];

    // Способ 1: удалить карточку через главный контроллер (работает и для карточек за экраном).
    id main = nil;
    Class mainCls = NSClassFromString(@"SBMainSwitcherViewController");
    if ([mainCls respondsToSelector:@selector(sharedInstance)]) {
        main = [mainCls sharedInstance];
    }
    BOOL canDelete = main && [main respondsToSelector:@selector(_deleteAppLayout:forReason:)];

    // Способ 2: закрыть контейнер карточки.
    BOOL canKill = [self respondsToSelector:@selector(killContainer:forReason:)] &&
                   [self respondsToSelector:@selector(_itemContainerForAppLayoutIfExists:)];

    NSLog(@"[QuickCloseAll] closing %lu cards (delete=%d, kill=%d)",
          (unsigned long)layouts.count, canDelete, canKill);

    for (id layout in layouts) {
        if (canDelete) {
            [main _deleteAppLayout:layout forReason:0];
        } else if (canKill) {
            id container = [self _itemContainerForAppLayoutIfExists:layout];
            if (container) [self killContainer:container forReason:0];
        }
    }
}

%end
