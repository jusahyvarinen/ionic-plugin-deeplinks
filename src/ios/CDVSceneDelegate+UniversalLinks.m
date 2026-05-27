// Only built on cordova-ios 8+ (older versions don't have CDVSceneDelegate).
#if __has_include(<Cordova/CDVSceneDelegate.h>)

#import <Cordova/CDVSceneDelegate.h>
#import <Cordova/CDVViewController.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "IonicDeeplinkPlugin.h"

// Forwards NSUserActivity (universal links) to IonicDeeplinkPlugin on cordova-ios 8.
// Cold start goes through willConnectToSession, warm resume through continueUserActivity.

@interface CDVSceneDelegate (UniversalLinks)
@end

// True when scene:continueUserActivity: was swizzled, false when we added it fresh.
// Used by the hook to decide if it should call the original.
static BOOL gWarmResumeSwizzled = NO;

@implementation CDVSceneDelegate (UniversalLinks)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self bzl_installColdStartHook];
        [self bzl_installWarmResumeHook];
    });
}

+ (void)bzl_installColdStartHook {
    // CDVSceneDelegate already implements willConnectToSession, so swizzle it.
    Method base = class_getInstanceMethod(self, @selector(scene:willConnectToSession:options:));
    Method swap = class_getInstanceMethod(self, @selector(bzl_scene:willConnectToSession:options:));
    if (base != NULL && swap != NULL) {
        method_exchangeImplementations(base, swap);
    }
}

+ (void)bzl_installWarmResumeHook {
    // scene:continueUserActivity: might be defined by another category.
    // Add it if missing, otherwise swizzle so we can call the original.
    SEL target = @selector(scene:continueUserActivity:);
    SEL ours = @selector(bzl_scene:continueUserActivity:);
    Method ourMethod = class_getInstanceMethod(self, ours);
    if (ourMethod == NULL) {
        return;
    }

    IMP ourIMP = method_getImplementation(ourMethod);
    const char *encoding = method_getTypeEncoding(ourMethod);

    if (class_addMethod(self, target, ourIMP, encoding)) {
        gWarmResumeSwizzled = NO;
        return;
    }
    Method targetMethod = class_getInstanceMethod(self, target);
    if (targetMethod != NULL) {
        method_exchangeImplementations(targetMethod, ourMethod);
        gWarmResumeSwizzled = YES;
    }
}

#pragma mark - Hooks

- (void)bzl_scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
          options:(UISceneConnectionOptions *)connectionOptions {
    // After the swap this selector points to the original implementation.
    [self bzl_scene:scene willConnectToSession:session options:connectionOptions];

    NSSet<NSUserActivity *> *pending = connectionOptions.userActivities;
    if (pending.count == 0) {
        return;
    }
    for (NSUserActivity *activity in pending) {
        [self bzl_dispatchUserActivity:activity];
    }
}

- (void)bzl_scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity {
    if (gWarmResumeSwizzled) {
        // Call the original implementation.
        [self bzl_scene:scene continueUserActivity:userActivity];
    }
    [self bzl_dispatchUserActivity:userActivity];
}

#pragma mark - Internal

- (void)bzl_dispatchUserActivity:(NSUserActivity *)activity {
    if (activity.webpageURL == nil) {
        return;
    }
    if (![activity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
        return;
    }

    CDVViewController *controller = [self bzl_resolveCordovaController:self.window.rootViewController];
    if (controller == nil) {
        NSLog(@"[IonicDeeplinks] No CDVViewController in scene window, dropping %@", activity.webpageURL);
        return;
    }

    IonicDeeplinkPlugin *plugin = (IonicDeeplinkPlugin *)[controller getCommandInstance:@"IonicDeeplinkPlugin"];
    if (plugin == nil) {
        NSLog(@"[IonicDeeplinks] Plugin not loaded, dropping %@", activity.webpageURL);
        return;
    }

    [plugin handleContinueUserActivity:activity];
}

- (CDVViewController *)bzl_resolveCordovaController:(UIViewController *)root {
    if (root == nil) {
        return nil;
    }
    if ([root isKindOfClass:[CDVViewController class]]) {
        return (CDVViewController *)root;
    }

    UIViewController *presented = root.presentedViewController;
    if (presented != nil) {
        CDVViewController *match = [self bzl_resolveCordovaController:presented];
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *child in root.childViewControllers) {
        CDVViewController *match = [self bzl_resolveCordovaController:child];
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

@end

#endif
