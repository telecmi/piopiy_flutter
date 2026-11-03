#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Starts the native call layer (PushKit + CallKit) at app launch — before any
// Flutter engine exists. A VoIP push can launch the app in the background
// with no UI scene; with the UIScene lifecycle no Flutter engine (and so no
// plugin registration) happens then, yet iOS requires the push to be
// reported to CallKit. React Native apps do this in AppDelegate; here it is
// automatic.
@interface PiopiyLaunch : NSObject
@end

@implementation PiopiyLaunch

+ (void)load {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    Class core = NSClassFromString(@"PiopiyCallCore");
                    SEL start = NSSelectorFromString(@"startAtLaunch");
                    if (core && [core respondsToSelector:start]) {
                        ((void (*)(id, SEL))[core methodForSelector:start])(core, start);
                    }
                }];
}

@end
