#import "include/AudioObjCTrap.h"

BOOL EliteSIPRunCatchingObjCException(void (NS_NOESCAPE ^block)(void),
                                      NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            // Имя и причина исключения — единственное, что вообще объясняет,
            // какой из форматов не сошёлся. Номер ошибки CoreAudio этого не
            // говорит, поэтому текст сохраняется целиком.
            NSString *reason = exception.reason ?: @"без объяснения";
            *error = [NSError errorWithDomain:@"com.elite.EliteSIP.audio"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@",
                                            exception.name, reason]
            }];
        }
        return NO;
    }
}
