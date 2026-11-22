import React from 'react';
import { useColorScheme, useWindowDimensions } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

// 契約: docs/ui-contract.md「表示条件画面」。アプリが受け取った外観と文字サイズの生の値を出すだけ。
// 文字サイズは OS の倍率(Android = Configuration.fontScale、iOS = UIContentSizeCategory から RN が算出した倍率。
// 段階名は RN から取れない)。useWindowDimensions は変更時に再描画される。
export function DisplayScreen() {
  const scheme = useColorScheme();
  const { fontScale } = useWindowDimensions();
  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtAppearance}>{scheme === 'dark' ? 'dark' : 'light'}</EchoText>
      <EchoText testID={Tags.txtTextSize}>{fontScale.toFixed(2)}</EchoText>
    </ScreenContainer>
  );
}
