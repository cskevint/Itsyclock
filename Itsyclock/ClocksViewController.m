//
//  ClocksViewController.m
//  Itsyclock
//
//  Menubar UI that shows multiple clocks for configured time zones.
//

#import "ClocksViewController.h"
#import "Itsyclock.h"
#import "ItsyclockWindow.h"
#import "MoButton.h"

static NSString * const kClocksStatusItemAutosaveName = @"ClocksStatusItem";

@interface ClocksViewController ()
@end

@implementation ClocksViewController
{
    NSArray<NSString *> *_timeZoneIDs;
    NSArray<NSDictionary *> *_clockEntries; // each: @{ "tz": tzID, "label": displayName }
    NSStatusItem *_statusItem;
    NSStackView *_stack;
    NSStackView *_rowsStack;
    NSStackView *_footer;
    MoButton *_btnPin;
    MoButton *_btnGear;
    NSTimer *_timer;
    NSDateFormatter *_menuFormatter;
    NSDateFormatter *_rowFormatter;
    BOOL _clockUsesSeconds;
}

- (void)dealloc
{
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View lifecycle

- (void)loadView
{
    NSView *v = [NSView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;

    _stack = [NSStackView new];
    _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _stack.spacing = 8;
#ifdef NSStackViewAlignmentLeading
    _stack.alignment = NSStackViewAlignmentLeading;
#else
    _stack.alignment = NSLayoutAttributeLeading; // fallback for older SDKs
#endif
    _stack.translatesAutoresizingMaskIntoConstraints = NO;

    _rowsStack = [NSStackView new];
    _rowsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _rowsStack.spacing = 0;
#ifdef NSStackViewAlignmentLeading
    _rowsStack.alignment = NSStackViewAlignmentLeading;
#else
    _rowsStack.alignment = NSLayoutAttributeLeading; // fallback for older SDKs
#endif
    _rowsStack.translatesAutoresizingMaskIntoConstraints = NO;

    _footer = [NSStackView new];
    _footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _footer.spacing = 6;
#ifdef NSStackViewAlignmentCenterY
    _footer.alignment = NSStackViewAlignmentCenterY;
#else
    _footer.alignment = NSLayoutAttributeCenterY; // fallback for older SDKs
#endif
    _footer.translatesAutoresizingMaskIntoConstraints = NO;

    _btnPin = [MoButton new];
    _btnPin.buttonType = NSButtonTypeToggle;
    _btnPin.image = [NSImage imageNamed:@"btnPin"];
    _btnPin.alternateImage = [NSImage imageNamed:@"btnPinAlt"];
    _btnPin.target = self;
    _btnPin.action = @selector(pin:);
    _btnPin.toolTip = NSLocalizedString(@"Pin Itsyclock", @"Pin popover");
    [_footer addArrangedSubview:_btnPin];

    _btnGear = [MoButton new];
    _btnGear.buttonType = NSButtonTypeMomentaryChange;
    _btnGear.image = [NSImage imageNamed:@"btnOpt"];
    _btnGear.target = self;
    _btnGear.action = @selector(showOptionsMenu:);
    _btnGear.toolTip = NSLocalizedString(@"Options", @"Options menu");
    [_footer addArrangedSubview:_btnGear];

    [_stack addArrangedSubview:_rowsStack];
    [_stack addArrangedSubview:_footer];

    [v addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:12],
        [_stack.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-12],
        [_stack.topAnchor constraintEqualToAnchor:v.topAnchor constant:12],
        [_stack.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-12],
        [_rowsStack.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor],
        [_rowsStack.trailingAnchor constraintEqualToAnchor:_stack.trailingAnchor],
        [_footer.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor],
        [_footer.trailingAnchor constraintEqualToAnchor:_stack.trailingAnchor]
    ]];

    self.view = v;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    _menuFormatter = [NSDateFormatter new];
    _rowFormatter = [NSDateFormatter new];

    [self loadTimeZoneIDs];
    [self configureFormatters];
    [self createStatusItem];
    [self rebuildRows];
    [self startTimer];
    [self updateStatusItemFont];
    [self updateStatusTitle];
    [self updateRowLabels];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(statusItemMoved:) name:NSWindowDidMoveNotification object:_statusItem.button.window];
    [nc addObserver:self selector:@selector(statusItemMoved:) name:NSWindowDidResizeNotification object:_statusItem.button.window];
    [nc addObserver:self selector:@selector(systemClockChanged:) name:NSSystemClockDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(systemClockChanged:) name:NSSystemTimeZoneDidChangeNotification object:nil];
}

- (void)viewDidAppear
{
    [super viewDidAppear];
    BOOL pinned = [[NSUserDefaults standardUserDefaults] boolForKey:kPinItsycal];
    _btnPin.state = pinned ? NSControlStateValueOn : NSControlStateValueOff;
    [self updatePinButtonAppearance];
}

#pragma mark - Setup

- (void)loadTimeZoneIDs
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *defaultsTZ = [defaults arrayForKey:kTimeZoneList];
    NSMutableArray *validTZ = [NSMutableArray new];
    for (NSString *tz in defaultsTZ) {
        if ([NSTimeZone timeZoneWithName:tz]) {
            [validTZ addObject:tz];
        }
    }

    // Always attempt to mirror Clock.app's configured world clocks at launch.
    NSArray<NSDictionary *> *clockAppEntries = [self clockAppEntries];
    if (clockAppEntries.count > 0) {
        _clockEntries = clockAppEntries;
        validTZ = [NSMutableArray arrayWithArray:[clockAppEntries valueForKey:@"tz"]];
    }

    // Still empty? Use seeded defaults.
    if (validTZ.count == 0) {
        validTZ = [@[
            NSTimeZone.localTimeZone.name,
            @"America/New_York",
            @"Europe/London",
            @"Asia/Tokyo"
        ] mutableCopy];
    }

    // Persist if defaults were empty originally and we populated from Clock.app or fallback.
    if (defaultsTZ.count == 0 && validTZ.count > 0) {
        [defaults setObject:validTZ forKey:kTimeZoneList];
    }

    _timeZoneIDs = validTZ.copy;

    // If we didn't get entries from Clock.app, synthesize labels from tz IDs.
    if (!_clockEntries) {
        NSMutableArray *entries = [NSMutableArray new];
        for (NSString *tz in _timeZoneIDs) {
            [entries addObject:@{ @"tz": tz, @"label": [self prettyNameForTimeZone:tz] }];
        }
        _clockEntries = entries;
    }
}

// Attempt to read the world clocks configured in Apple's Clock.app (Ventura+).
- (NSArray<NSDictionary *> *)clockAppEntries
{
    NSArray<NSString *> *candidatePaths = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Containers/com.apple.clock/Data/Library/Preferences/com.apple.mobiletimer.plist"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Containers/com.apple.Clock/Data/Library/Preferences/com.apple.mobiletimer.plist"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Containers/com.apple.Clock/Data/Library/Preferences/com.apple.worldclock.plist"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Containers/com.apple.Clock/Data/Library/Preferences/com.apple.clock.plist"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.apple.worldclock.plist"]
    ];

    for (NSString *path in candidatePaths) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![plist isKindOfClass:[NSDictionary class]]) continue;

        // New Clock.app (mobiletimer) format uses "cities" array with nested "city" dicts.
        NSArray *cities = plist[@"cities"] ?: plist[@"WorldClockCities"];
        if (![cities isKindOfClass:[NSArray class]]) continue;

        NSMutableArray *result = [NSMutableArray new];
        for (id item in cities) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *dict = (NSDictionary *)item;
            NSDictionary *cityDict = dict[@"city"] ?: dict;
            NSString *tz = cityDict[@"timeZone"] ?: cityDict[@"Timezone"] ?: cityDict[@"TimeZone"] ?: cityDict[@"TimeZoneName"];
            if (tz.length == 0) continue;
            if (![NSTimeZone timeZoneWithName:tz]) continue;
            NSString *cityName = cityDict[@"name"] ?: cityDict[@"unlocalizedName"] ?: tz;
            NSString *country = cityDict[@"countryName"] ?: cityDict[@"unlocalizedCountryName"] ?: @"";
            NSString *label = country.length ? [NSString stringWithFormat:@"%@, %@", cityName, country] : cityName;
            if (![result filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"tz == %@", tz]].count) {
                [result addObject:@{ @"tz": tz, @"label": label }];
            }
        }
        if (result.count > 0) return result;
    }
    return @[];
}

- (void)configureFormatters
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Force 12-hour format with AM/PM per user request.
    BOOL use24 = NO;
    _clockUsesSeconds = [defaults boolForKey:kShowSecondsInClock];

    NSString *menuPattern = use24 ? (_clockUsesSeconds ? @"HH:mm:ss" : @"HH:mm")
                                   : (_clockUsesSeconds ? @"h:mm:ss a" : @"h:mm a");
    NSString *rowPattern  = use24 ? (_clockUsesSeconds ? @"EEE HH:mm:ss" : @"EEE HH:mm")
                                   : (_clockUsesSeconds ? @"EEE h:mm:ss a" : @"EEE h:mm a");

    _menuFormatter.dateFormat = menuPattern;
    _rowFormatter.dateFormat = rowPattern;
}

- (void)startTimer
{
    [_timer invalidate];
    NSTimeInterval interval = _clockUsesSeconds ? 1.0 : 60.0;
    _timer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(tick) userInfo:nil repeats:YES];
    if (_timer) {
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)createStatusItem
{
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.target = self;
    _statusItem.button.action = @selector(statusItemClicked:);
    [_statusItem.button sendActionOn:NSEventMaskLeftMouseDown];
    [_statusItem setAutosaveName:kClocksStatusItemAutosaveName];
}

#pragma mark - Timer

- (void)tick
{
    [self updateStatusTitle];
    [self updateRowLabels];
}

#pragma mark - Status item

- (void)statusItemClicked:(id)sender
{
    if ([self clocksWindow].occlusionState & NSWindowOcclusionStateVisible) {
        [self hideClocksWindow];
    }
    else {
        [self showClocksWindow];
    }
}

- (void)updateStatusTitle
{
    NSString *primaryID = _timeZoneIDs.firstObject ?: NSTimeZone.localTimeZone.name;
    _menuFormatter.timeZone = [NSTimeZone timeZoneWithName:primaryID] ?: NSTimeZone.localTimeZone;
    [self configureFormatters];
    [self updateStatusItemFont];

    NSString *title = [_menuFormatter stringFromDate:[NSDate date]] ?: @"";
    _statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:title
                                                                          attributes:@{NSBaselineOffsetAttributeName: @0}];
    _statusItem.button.accessibilityTitle = [NSString stringWithFormat:@"Primary clock: %@", title];
}

- (void)updateStatusItemFont
{
    NSFont *font = _clockUsesSeconds ? [NSFont monospacedDigitSystemFontOfSize:0 weight:NSFontWeightRegular]
                                    : [NSFont systemFontOfSize:0 weight:NSFontWeightRegular];
    _statusItem.button.font = font;
}

- (void)removeStatusItem
{
    if (_statusItem) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidMoveNotification object:_statusItem.button.window];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResizeNotification object:_statusItem.button.window];
    }
}

#pragma mark - Rows

- (void)rebuildRows
{
    for (NSView *view in [_rowsStack.arrangedSubviews copy]) {
        [_rowsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSDictionary *entry in _clockEntries) {
        NSString *tzID = entry[@"tz"];
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzID];
        if (!tz) continue;

        NSStackView *row = [NSStackView new];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 12;
        #ifdef NSStackViewAlignmentCenterY
        row.alignment = NSStackViewAlignmentCenterY;
        #else
        row.alignment = NSLayoutAttributeCenterY; // fallback for older SDKs
        #endif
        row.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *cityLabel = [NSTextField labelWithString:entry[@"label"] ?: tzID];
        cityLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        cityLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        cityLabel.maximumNumberOfLines = 1;
        [cityLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
        [cityLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSTextField *timeLabel = [NSTextField labelWithString:@""];
        timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
        timeLabel.identifier = tzID;
        timeLabel.alignment = NSTextAlignmentRight;
        [timeLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [timeLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

        [row addArrangedSubview:cityLabel];
        [row addArrangedSubview:timeLabel];

        [_rowsStack addArrangedSubview:row];
        [row.leadingAnchor constraintEqualToAnchor:_rowsStack.leadingAnchor].active = YES;
        [row.trailingAnchor constraintEqualToAnchor:_rowsStack.trailingAnchor].active = YES;

        // Pin columns for consistent alignment.
        [cityLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor].active = YES;
        [timeLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor].active = YES;
        [timeLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:cityLabel.trailingAnchor constant:12].active = YES;
    }
}

- (void)updateRowLabels
{
    NSDate *now = [NSDate date];
    NSArray *sorted = [self sortedEntriesByLocalTime:now];
    if (![self entries:_clockEntries equalOrderTo:sorted]) {
        _clockEntries = sorted;
        [self rebuildRows];
    }
    for (NSView *row in _rowsStack.arrangedSubviews) {
        if (![row isKindOfClass:[NSStackView class]]) continue;
        NSArray *subviews = ((NSStackView *)row).arrangedSubviews;
        if (subviews.count < 2) continue;
        NSTextField *cityLabel = (NSTextField *)subviews.firstObject;
        NSTextField *timeLabel = (NSTextField *)subviews.lastObject;
        if (![timeLabel isKindOfClass:[NSTextField class]]) continue;
        NSString *tzID = timeLabel.identifier;
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzID];
        if (!tz) continue;
        _rowFormatter.timeZone = tz;
        NSString *labelText = entryForTZ(@"label", tzID, _clockEntries) ?: [self prettyNameForTimeZone:tzID];
        NSString *timeString = [_rowFormatter stringFromDate:now] ?: @"";
        cityLabel.stringValue = labelText;
        timeLabel.stringValue = timeString;
    }
}

static NSString *entryForTZ(NSString *key, NSString *tzID, NSArray<NSDictionary *> *entries)
{
    for (NSDictionary *entry in entries) {
        if ([entry[@"tz"] isEqualToString:tzID]) {
            return entry[key];
        }
    }
    return nil;
}

- (NSArray<NSDictionary *> *)sortedEntriesByLocalTime:(NSDate *)now
{
    return [_clockEntries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSTimeZone *tza = [NSTimeZone timeZoneWithName:a[@"tz"]];
        NSTimeZone *tzb = [NSTimeZone timeZoneWithName:b[@"tz"]];
        if (!tza) return NSOrderedDescending;
        if (!tzb) return NSOrderedAscending;
        NSInteger sa = [self secondsIntoDayForDate:now timeZone:tza];
        NSInteger sb = [self secondsIntoDayForDate:now timeZone:tzb];
        if (sa == sb) return NSOrderedSame;
        return sa < sb ? NSOrderedAscending : NSOrderedDescending;
    }];
}

- (NSInteger)secondsIntoDayForDate:(NSDate *)date timeZone:(NSTimeZone *)tz
{
    NSCalendar *cal = [NSCalendar autoupdatingCurrentCalendar];
    cal = [cal copy];
    cal.timeZone = tz;
    NSDateComponents *c = [cal components:(NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond) fromDate:date];
    return c.hour * 3600 + c.minute * 60 + c.second;
}

- (BOOL)entries:(NSArray<NSDictionary *> *)a equalOrderTo:(NSArray<NSDictionary *> *)b
{
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        NSString *atz = a[i][@"tz"];
        NSString *btz = b[i][@"tz"];
        if (![atz isEqualToString:btz]) return NO;
    }
    return YES;
}

- (NSString *)prettyNameForTimeZone:(NSString *)tzID
{
    NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzID];
    NSString *localized = [tz localizedName:NSTimeZoneNameStyleStandard locale:[NSLocale currentLocale]];
    if (localized.length > 0) return localized;
    NSArray *parts = [tzID componentsSeparatedByString:@"/"];
    return parts.lastObject ? [parts.lastObject stringByReplacingOccurrencesOfString:@"_" withString:@" "] : tzID;
}

#pragma mark - Window

- (ItsyclockWindow *)clocksWindow
{
    return (ItsyclockWindow *)self.view.window;
}

- (void)showClocksWindow
{
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    [self positionClocksWindow];
    [[self clocksWindow] makeKeyAndOrderFront:self];
}

- (void)hideClocksWindow
{
    [[self clocksWindow] orderOut:self];
}

- (void)positionClocksWindow
{
    if (!_statusItem.button.window) return;
    NSRect statusItemFrame = [_statusItem.button.window convertRectToScreen:_statusItem.button.frame];
    NSScreen *screen = _statusItem.button.window.screen ?: [NSScreen mainScreen];
    CGFloat screenMaxX = NSMaxX(screen.frame);
    [[self clocksWindow] positionRelativeToRect:statusItemFrame screenMaxX:screenMaxX];
}

- (void)statusItemMoved:(NSNotification *)note
{
    // Delay slightly so menu-bar geometry is stable.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self positionClocksWindow];
    });
}

#pragma mark - Actions

- (void)pin:(id)sender
{
    BOOL pinned = (_btnPin.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:kPinItsycal];
    [self updatePinButtonAppearance];
    if (pinned) {
        [[self clocksWindow] makeKeyAndOrderFront:self];
    }
}

- (void)updatePinButtonAppearance
{
    BOOL pinned = (_btnPin.state == NSControlStateValueOn);
    NSImage *img = [NSImage imageNamed:pinned ? @"btnPinAlt" : @"btnPin"];
    [_btnPin setImage:img];
}

- (void)showOptionsMenu:(id)sender
{
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:NSLocalizedString(@"Date & Time Settings...", @"Open Date & Time settings") action:@selector(openDateAndTimePrefs:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"Quit Itsyclock", @"Quit") action:@selector(terminate:) keyEquivalent:@""];

    NSPoint p = NSMakePoint(NSMinX(_btnGear.bounds), NSMaxY(_btnGear.bounds) + 2);
    [menu popUpMenuPositioningItem:nil atLocation:p inView:_btnGear];
}

- (void)openDateAndTimePrefs:(id)sender
{
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.datetime"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - Notifications

- (void)systemClockChanged:(NSNotification *)note
{
    [self tick];
}

#pragma mark - NSWindowDelegate

- (void)windowDidResignKey:(NSNotification *)notification
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kPinItsycal]) {
        [self hideClocksWindow];
    }
}

#pragma mark - Keyboard shortcut

- (void)keyboardShortcutActivated
{
    [self statusItemClicked:self];
}

@end
