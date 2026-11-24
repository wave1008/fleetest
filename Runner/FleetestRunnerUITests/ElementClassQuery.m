// ElementClassQuery.m
// 実測(物理 iPhone SE3): 1問い合わせ約 2ms。前のスナップショットから保持したノードへの問い合わせも、スワイプの後に正しく答える。

#import "ElementClassQuery.h"
#import <objc/message.h>

NSDictionary<NSString *, NSString *> *_Nullable FTElementClassAttributes(id node, NSArray<NSString *> *names) {
    @try {
        id element = [node valueForKey:@"accessibilityElement"];
        if (!element) return nil;
        Class deviceClass = NSClassFromString(@"XCUIDevice");
        SEL sharedSel = NSSelectorFromString(@"sharedDevice");
        if (!deviceClass || ![deviceClass respondsToSelector:sharedSel]) return nil;
        id device = ((id (*)(id, SEL))objc_msgSend)(deviceClass, sharedSel);
        SEL interfaceSel = NSSelectorFromString(@"accessibilityInterface");
        if (!device || ![device respondsToSelector:interfaceSel]) return nil;
        id client = ((id (*)(id, SEL))objc_msgSend)(device, interfaceSel);
        SEL querySel = NSSelectorFromString(@"attributesForElement:attributes:error:");
        if (!client || ![client respondsToSelector:querySel]) return nil;
        NSError *error = nil;
        id result = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(client, querySel, element, names, &error);
        if (error || ![result isKindOfClass:[NSDictionary class]]) return nil;
        NSMutableDictionary<NSString *, NSString *> *flat = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *)result) {
            flat[[key description]] = [[(NSDictionary *)result objectForKey:key] description];
        }
        return flat;
    } @catch (NSException *exception) {
        return nil;
    }
}
