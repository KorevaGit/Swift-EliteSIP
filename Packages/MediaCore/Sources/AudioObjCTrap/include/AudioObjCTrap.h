#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Выполняет блок, превращая исключение Objective-C в NSError.
///
/// Существует ради `AVAudioEngine`: несовпадение формата с текущим форматом
/// железа он сообщает не ошибкой, а `NSException` — например «Input HW format
/// and tap format not matching». Swift исключения Objective-C не ловит, поэтому
/// без этой прослойки любая гонка при смене звукового устройства кладёт весь
/// процесс. А гонка настоящая: между чтением формата и подключением узла
/// железо успевает переключиться.
///
/// Возвращает YES, если блок отработал без исключения.
BOOL EliteSIPRunCatchingObjCException(void (NS_NOESCAPE ^block)(void),
                                      NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
