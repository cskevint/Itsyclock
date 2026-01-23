//
//  ClocksViewController.h
//  Itsyclock
//
//  A lightweight menubar controller that lists multiple time zones.
//

#import <Cocoa/Cocoa.h>

@interface ClocksViewController : NSViewController <NSWindowDelegate>

- (void)keyboardShortcutActivated;
- (void)removeStatusItem;

@end
