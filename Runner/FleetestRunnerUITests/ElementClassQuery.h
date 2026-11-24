// ElementClassQuery.h
// XCTest の非公開 API(XCUIDevice.accessibilityInterface の attributesForElement:attributes:error:)で、
// 取得済みのスナップショットのノードに属性を問い合わせる。属性は**名前の文字列**で渡す(番号では受け付けない)。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ノード(XCUIElementSnapshot)の属性を名前で引く。結果の値は文字列化したもの。
/// 非公開 API が無い・例外・エラーのときは nil(呼び手は「不明」に縮退する)。
NSDictionary<NSString *, NSString *> *_Nullable FTElementClassAttributes(id node, NSArray<NSString *> *names);

NS_ASSUME_NONNULL_END
