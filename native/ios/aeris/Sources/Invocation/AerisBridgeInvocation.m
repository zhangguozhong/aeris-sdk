#import "AerisBridgeInvocation.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

// 属性 setter 也可能使用 void(id) ABI，因此需要显式排除。
static BOOL AerisIsPropertyAccessor(Class cls, SEL selector) {
    for (Class current = cls; current && current != NSObject.class;
         current = class_getSuperclass(current)) {
        unsigned count = 0;
        objc_property_t *properties = class_copyPropertyList(current, &count);
        BOOL found = NO;
        for (unsigned i = 0; i < count && !found; i++) {
            const char *name = property_getName(properties[i]);
            char *getter = property_copyAttributeValue(properties[i], "G");
            char *setter = property_copyAttributeValue(properties[i], "S");
            NSString *propertyName = @(name);
            NSString *defaultSetter = [NSString
                stringWithFormat:@"set%@%@:", [[propertyName substringToIndex:1] uppercaseString],
                                 [propertyName substringFromIndex:1]];
            found = selector == sel_registerName(getter ?: name) ||
                    selector == NSSelectorFromString(setter ? @(setter) : defaultSetter);
            free(getter);
            free(setter);
        }
        free(properties);
        if (found)
            return YES;
    }
    return NO;
}

@implementation AerisBridgeInvocation
+ (SEL)lookupTarget:(NSObject *)target methodName:(NSString *)methodName {
    SEL selector = NSSelectorFromString([methodName stringByAppendingString:@":"]);
    if (class_getInstanceMethod(NSObject.class, selector) ||
        AerisIsPropertyAccessor(object_getClass(target), selector))
        return NULL;
    for (Class cls = object_getClass(target); cls && cls != NSObject.class;
         cls = class_getSuperclass(cls)) {
        unsigned count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        BOOL found = NO;
        for (unsigned i = 0; i < count; i++)
            if (method_getName(methods[i]) == selector) {
                found = YES;
                break;
            }
        free(methods);
        if (found)
            return selector;
    }
    return NULL;
}
+ (BOOL)validateTarget:(NSObject *)target selector:(SEL)selector {
    if (!target || !selector || ![target respondsToSelector:selector])
        return NO;
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!method || method_getNumberOfArguments(method) != 3)
        return NO;
    char result[32] = {0}, argument[32] = {0};
    method_getReturnType(method, result, sizeof(result));
    method_getArgumentType(method, 2, argument, sizeof(argument));
    // 拒绝 block（@?）、标量、指针和非 void 返回值。
    return strcmp(result, "v") == 0 && strcmp(argument, "@") == 0;
}
+ (BOOL)invokeTarget:(NSObject *)target selector:(SEL)selector session:(NSObject *)session {
    if (![self validateTarget:target selector:selector])
        return NO;
    @try {
        // 此函数指针签名与 @objc func method(_ session: ...) -> Void 的 ABI 一致。
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, session);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
@end
