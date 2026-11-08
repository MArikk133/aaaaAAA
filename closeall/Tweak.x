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

static BOOL gSwitcherKnown = NO;    // получали ли мы сигнал о показе/скрытии переключателя
static BOOL gSwitcherVisible = NO;
static __weak SBFluidSwitcherViewController *gVC;
static NSTimer *gTimer;

#pragma mark - Видимость

// Реально ли вью видно на экране: в окне, не скрыто и не прозрачно по всей цепочке.
static BOOL ViewReallyVisible(UIView *v) {
    if (!v.window) return NO;
    if (v.window.hidden || v.window.alpha < 0.05) return NO;
    for (UIView *x = v; x; x = x.superview) {
        if (x.hidden || x.alpha < 0.05) return NO;
    }
    return YES;
}

static BOOL ShouldShowButton(SBFluidSwitcherViewController *vc) {
    if (!vc.isViewLoaded || !ViewReallyVisible(vc.view)) return NO;
    if (gSwitcherKnown && !gSwitcherVisible) return NO;
    if (![vc respondsToSelector:@selector(appLayouts)]) return NO;
    NSArray *layouts = vc.appLayouts;
    return [layouts isKindOfClass:[NSArray class]] && layouts.count > 0;
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

    BOOL show = ShouldShowButton(vc);
    if (show && b.hidden) {
        b.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{ b.alpha = 1.0; }];
    } else if (!show && !b.hidden) {
        b.alpha = 0.0;
        b.hidden = YES;
    }
}

static void StartTimer(void) {
    if (gTimer) return;
    // Лёгкая проверка 4 раза в секунду: показать или спрятать кнопку.
    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
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

// Сигналы о показе и скрытии переключателя (если контроллер их присылает).
%hook SBMainSwitcherViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gSwitcherKnown = YES;
    gSwitcherVisible = YES;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    gSwitcherKnown = YES;
    gSwitcherVisible = NO;
}

%end
