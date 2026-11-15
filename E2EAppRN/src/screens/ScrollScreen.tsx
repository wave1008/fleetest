import React, { useEffect, useRef, useState } from 'react';
import { FlatList, Platform, StyleSheet, View, ViewToken } from 'react-native';

import { rowCount, tag, tagCount, tagLabel, Tags, row, rowLabel } from '../tags';
import { EchoText, TaggedButton } from '../ui';

// ティッカーの周期(ms)。シナリオの静止の窓 0.5 秒より十分短く、動作中は窓あたり 5 回変わって静止が成立しない
const TICKER_INTERVAL_MS = 100;

const ROWS = Array.from({ length: rowCount }, (_, i) => i + 1);
const CAROUSEL = Array.from({ length: tagCount }, (_, i) => i + 1);

// FlatList は仮想化される(RN の現実に合わせた実装。契約の cacheExtent:0 相当の対策は無いため、
// 初期描画本数を絞って画面外行が広く先読みされないようにする)。
// #list_rows は容器そのものを公開する(スコープセレクタの対象)。コンテナ View に
// accessible={true} は付けない(子の testID が畳まれて消える罠を避ける)。
export function ScrollScreen() {
  const [selected, setSelected] = useState('-');
  const [tagSelected, setTagSelected] = useState('-');
  const [topRow, setTopRow] = useState(1);
  const listRef = useRef<FlatList<number>>(null);
  const [tickerRunning, setTickerRunning] = useState(false);
  const [ticker, setTicker] = useState(0);

  // setInterval で回す(アニメーション API でないのでアニメ無効設定で止まらない)。停止・画面を離れると clear される
  useEffect(() => {
    if (!tickerRunning) {
      return undefined;
    }
    const id = setInterval(() => setTicker(n => n + 1), TICKER_INTERVAL_MS);
    return () => clearInterval(id);
  }, [tickerRunning]);

  // #txt_scroll_top(先頭に一部でも見えている行。docs/ui-contract.md §スクロール画面)。
  // 行の実効高さが固定でない(minHeight + margin)ので offset からは割らず FlatList の可視判定を使う
  const onViewableItemsChanged = useRef(
    ({ viewableItems }: { viewableItems: ViewToken[] }) => {
      const indices = viewableItems
        .map(v => v.index)
        .filter((i): i is number => i !== null && i !== undefined);
      if (indices.length > 0) {
        setTopRow(Math.min(...indices) + 1);
      }
    }
  ).current;
  const viewabilityConfig = useRef({ itemVisiblePercentThreshold: 1 }).current;

  // OI-218 の測る口(Android だけ・判定には使わない): 一覧が受けた直近 4 本のタッチ列を `#list_rows` のラベルに載せる。
  // 1本 = `m<移動の数><e 離した|c 取り消し = ScrollView が引き取った><終わった ms>y<始まりの位置>:<次のタッチまでの最小>-<最大>`
  // (位置は onScroll の contentOffset.y・dp。新しい順)。onScrollBeginDrag は取り消しの後に届くので使わない。
  // 表示を足すと一覧が縮み契約(#row_06 まで完全に見える)が崩れるのでラベルに載せる。iOS は載せない
  const [trace, setTrace] = useState('trace=-');
  const scrollY = useRef(0);
  const touch = useRef({ start: 0, moves: 0, end: '', y0: 0, min: 0, max: 0 });
  const history = useRef<string[]>([]);
  const entry = (t: typeof touch.current) =>
    `m${t.moves}${t.end || '?'}y${Math.round(t.y0)}:${Math.round(t.min)}-${Math.round(t.max)}`;
  const publish = () => {
    const t = touch.current;
    const parts = t.start > 0 ? [entry(t), ...history.current] : history.current;
    setTrace(`trace=${parts.slice(0, 4).join(' ')}`);
  };
  const traceProps =
    Platform.OS === 'android'
      ? {
          accessibilityLabel: trace,
          scrollEventThrottle: 16,
          onScroll: (e: { nativeEvent: { contentOffset: { y: number } } }) => {
            const y = e.nativeEvent.contentOffset.y;
            scrollY.current = y;
            const t = touch.current;
            if (t.start > 0) {
              t.min = Math.min(t.min, y);
              t.max = Math.max(t.max, y);
            }
          },
          onTouchStart: () => {
            if (touch.current.start > 0) {
              const done = entry(touch.current);
              history.current = [done, ...history.current].slice(0, 4);
              // logcat(ReactNativeJS)にも残す: 要素一覧はラベルを途中で切るので、赤の回の探索の払いは logcat で読む
              console.log(`OI218 ${done}`);
            }
            const y = scrollY.current;
            touch.current = { start: Date.now(), moves: 0, end: '', y0: y, min: y, max: y };
          },
          onTouchMove: () => {
            touch.current.moves += 1;
          },
          onTouchEnd: () => {
            touch.current.end = `e${Date.now() - touch.current.start}`;
            publish();
          },
          onTouchCancel: () => {
            touch.current.end = `c${Date.now() - touch.current.start}`;
            publish();
          },
          onMomentumScrollEnd: publish,
          onScrollEndDrag: publish,
        }
      : {};

  return (
    <View style={styles.container}>
      {/* #txt_ticker は selected の横に置く(縦に足すとリストが縮む) */}
      <View style={styles.headerRow}>
        <EchoText testID={Tags.txtRowSelected}>{`selected=${selected}`}</EchoText>
        <EchoText testID={Tags.txtTicker}>{`ticker=${ticker}`}</EchoText>
      </View>
      {/* #txt_scroll_top はボタンの横に置く(縦に足すとリストが縮み、契約の「#row_06 まで完全に見える」が崩れる) */}
      <View style={styles.headerRow}>
        <TaggedButton
          testID={Tags.btnScrollTop}
          label="先頭へ"
          onPress={() => listRef.current?.scrollToOffset({ offset: 0, animated: false })}
        />
        <EchoText testID={Tags.txtScrollTop}>{`top=${row(topRow)}`}</EchoText>
        <TaggedButton
          testID={Tags.btnTickerToggle}
          label={tickerRunning ? 'ティッカー停止' : 'ティッカー開始'}
          style={styles.tickerButton}
          onPress={() => setTickerRunning(r => !r)}
        />
      </View>
      <FlatList
        testID={Tags.listRows}
        {...traceProps}
        ref={listRef}
        style={styles.list}
        data={ROWS}
        keyExtractor={n => row(n)}
        initialNumToRender={8}
        windowSize={3}
        // iOS は既定 false のため先読み行が実座標のままツリーに残り
        // scroll-leftover 警告の対象になる(Flutter の cacheExtent:0 と同じ趣旨)
        removeClippedSubviews
        // 下端の余白: 最終行がビューポート下端に貼り付いたままだと座標タップが外れやすい。
        contentContainerStyle={{ paddingBottom: 80 }}
        onViewableItemsChanged={onViewableItemsChanged}
        viewabilityConfig={viewabilityConfig}
        renderItem={({ item: n }) => (
          <TaggedButton
            testID={row(n)}
            label={rowLabel(n)}
            style={styles.row}
            onPress={() => setSelected(row(n))}
          />
        )}
      />
      {/* 横スクロールの検証材料(scrollFrame)。リストの下・画面下部に置く(中央に置くと
          領域指定なしの従来スクロールがカルーセルに吸われる)。1画面に3〜4個しか入らない幅。 */}
      <FlatList
        testID={Tags.carouselTags}
        horizontal
        data={CAROUSEL}
        keyExtractor={n => tag(n)}
        initialNumToRender={4}
        windowSize={3}
        removeClippedSubviews
        style={styles.carousel}
        renderItem={({ item: n }) => (
          <TaggedButton
            testID={tag(n)}
            label={tagLabel(n)}
            style={styles.tagButton}
            onPress={() => setTagSelected(tag(n))}
          />
        )}
      />
      <EchoText testID={Tags.txtTagSelected}>{`tag=${tagSelected}`}</EchoText>
    </View>
  );
}

const styles = StyleSheet.create({
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  container: {
    flex: 1,
    padding: 16,
    gap: 8,
  },
  // 360 幅で 1 行に収めるため横パディングを詰める
  tickerButton: {
    paddingHorizontal: 10,
  },
  list: {
    flex: 1,
  },
  row: {
    minHeight: 56,
    alignItems: 'flex-start',
    justifyContent: 'center',
    marginBottom: 2,
  },
  carousel: {
    height: 60,
    flexGrow: 0,
  },
  tagButton: {
    width: 120,
    minHeight: 56,
    marginRight: 8,
  },
});
