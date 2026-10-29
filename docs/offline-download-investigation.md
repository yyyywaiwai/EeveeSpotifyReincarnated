# Votify を応用した端末内ダウンロード統合の調査

2026-10-26 更新。以下の旧調査記録に加え、**iOS PlayPlay の鍵レコードを使った直接復号・保存・通信遮断後のオフライン再生**を実機で確認した。通常再生中の曲に加え、アルバムの自然な鍵先読みを使った未再生の次曲1件も固定条件で実証した。純正ダウンロードボタンの操作を Eevee の保存処理へ接続し、単曲・2曲アルバムの保存済み曲をマイライブラリ内の Eevee 行からオフライン再生した。ただし2曲は各曲を事前に通常再生して鍵を得た条件付きである。調査用 Frida での実証と、製品コード／deb の動作確認は区別する。

### 2026-10-26: 2曲プレイリストの製品版一括保存

- rootless `7.0.0-26` を iPhone 12 mini の Spotify 9.1.88 に導入した。公開2曲プレイリストの全曲URI・順序を端末内のカタログ応答で照合し、既存の保存済み7曲との重複がないことを確認した。純正スロットの Eevee ダウンロードボタンは表示・タッチ可能だった。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/two-track-playlist-readonly-26-28adb8128d1c.json`（0600）。
- Spotify がページ表示から16秒後の通常再生タップで同じ `ActionView` を再び隠したとき、`-26` の限定 hook が同じボタンを表示し直し、`HeaderActionsRow` の配置と `hitTest` を維持した。Spotify 側の実際の hide の約13ms後に Eevee 側の reveal を観測した。この試験では保存操作をしていない。証拠は `Outputs/work/playplay-bulk-20261026/evidence/playlist-action-hide-source-26-7fe5e7083ee4.json`（0600）。
- 同じ公開プレイリストで**両曲を先に通常再生して各曲の PlayPlay 鍵を得た後**、表示されたダウンロードボタンを1回押した。押下直前に両鍵、カタログ順序、ボタンの `hitTest` を確認し、製品の全件完了表示と保存済みチェックマーク、索引・有効WAVの7→9件、元の7曲のSHA不変を実機で確認した。部分成功を全件成功として扱った結果ではない。証拠は `Outputs/work/playplay-bulk-20261026/evidence/two-track-playlist-save-proof-26-ccda6ad62b93.json`（0600）。
- 保存後に Wi-Fi と外部TCPを遮断し、マイライブラリ内の Eevee 保存行から2曲をそれぞれ1回タップした。各曲のローカルプレイヤー・タイトルと再生位置の3秒超の進行を確認し、通信復元後も索引9件・WAV9件の全SHAが即時・2秒後・4秒後に不変だった。初回試行は9行表示でプレイヤー欄が画面外にあるのを未表示と判定し、再生の成否を確定できなかった。次の試行でタップ後に縦スクロールして欄を確認し、**2曲とも通信遮断下の再生を実証**した。証拠は `Outputs/work/playplay-bulk-20261026/evidence/two-track-playlist-offline-replay-26-5196ff2cf4f4.json` と `two-track-playlist-offline-replay-26-71c4976f2ef7.json`（0600）。
- 未再生曲の鍵先読みを探る値非出力の受動 probe は、通常UIでタップした対象曲の再生URI一致に失敗したため、結果は `observation_gate_failed`。この回は head-file dispatch 0件、自然な provider mode 2 要求1件だったが、そのIDは直近の再生owner IDと一致せず、候補からprovider要求までの連鎖は確認できなかった。保存済み索引9件・WAV9件は不変で、通信と前面アプリを復元した。証拠は `Outputs/work/playplay-bulk-20261026/evidence/headfile-playplay-correlation-26-faedaec1ec38.json`（0600）。
- 任意の未再生曲すべての鍵をボタン1回だけで取得する経路は未確立のため、今回の成功条件は事前の2曲通常再生を含む。後続のホスト調査で Spotify 9.1.88 の完全復号IPAを取得し、IPA向けInternalバックエンドとPlayPlay call-site graftを組み込んだ未署名IPAを作成・構造検証した。非脱獄端末での動作確認はしていない。

### 2026-10-27: 5曲アルバムの製品版一括保存

- 公開5曲アルバムの全曲を端末内 Pathfinder 応答で照合し、既存の保存済み9曲との重複がないことと、純正スロットの Eevee ダウンロードボタンが操作可能なことを読み取り専用で確認した。曲行の AX／幾何と短いスクロールも保存操作なしで校正した。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/blue-train-five-readonly-26-0265d7efa0e9.json` と `blue-train-five-scroll-calibration-26-0e5696359155.json`（0600）。
- 先頭と4曲目だけを通常再生した先行試験では、2曲目の metadata file ID に対応する鍵が15秒後もなく、**保存ボタンは押さず**、索引9件／WAV9件を維持した。全曲自然先読みが起きるという仮定を成功条件にしていない。証拠は `blue-train-five-save-proof-26-e39305c72d30.json`（0600）。
- 別の単回試験で、5曲の行を順番に通常再生し、各再生URI・format-0 metadata file ID と鍵を一致させた。5件の file ID は相異なり、最後の曲の後も5件すべての鍵が保持され、世代が安定していることを保存前に確認した。純正スロットの Eevee ボタンを**1回だけ**押すと、製品は5/5完了ポップアップと保存済みチェックマークを表示し、索引・有効WAVは9→14件、一時ファイルは最終0件だった。新規5件の曲名・アーティスト・WAV形式・再生時間を照合し、元9件のSHAは不変。Spotifyを終了して X 前面、通信復元、全14件のSHA不変を即時・2秒後・4秒後に確認した。値を伏せた証拠は `Outputs/work/playplay-bulk-20261026/evidence/blue-train-five-all-play-save-proof-26-1e7f084cc97c.json`（0600）。**通信遮断後の新規5曲の再生と、未再生5曲をボタン1回のみで鍵取得する動作はこの証拠に含まれない。**
- 続く通信遮断後の再生試験では、Eeveeライブラリの保存曲1・2件目をそれぞれタップし、ローカルプレーヤーの再生位置が3秒超進むことと外部TCP失敗を確認した。3件目は行ラベルと14行の存在が一致したものの、行中心が画面下の y=657 に留まり、8回のスクロール後も `hitTest` 不成立だったため**タップせず停止**した。4・5件目の再生は未検証。保存操作0、索引14件／WAV14件の全SHA不変、通信・X前面・Spotify停止の復元を即時・2秒後・4秒後に確認した。証拠は `Outputs/work/playplay-bulk-20261026/evidence/blue-train-five-offline-replay-26-a6afc0eff4a1.json`（0600）。
- スクロール不動の原因を別の可逆校正で切り分けた。旧操作の開始点 `(185,595)` は Eevee 行の `UIButton` 上だった。`(185,165)` は同じ section／collection の非 `UIControl` view で、pan は idle・collection に可動域がある。この点から上へ100ptの1スワイプで content offset は -820→-735、3件目の中心は y=657→572、`hitTest` は不成立→成立になった。行／保存タップ0、索引・WAV14件と全SHA、通信・前面状態は復元。これは**スクロール経路の校正**で、3〜5件目の再生証明ではない。証拠は `Outputs/work/playplay-bulk-20261026/evidence/blue-train-inline-scroll-calibration-26-13356f7ad8dd.json` と `blue-train-heading-swipe-calibration-26-5b48ebc7727c.json`（0600）。

### 多曲アルバム／プレイリスト一括保存の追加ゴール

- `OfflineCollectionCatalog.fetch(uri:)` の全ページ集約をホスト fixture で検査し、件数変更・ページ超過・不正 track URI を拒否する。プレイリストに同じ track URI が複数回ある場合は元の出現順を保持し、保存ジョブ用の `uniqueTrackURIs` だけ重複を除く。`swiftc -warnings-as-errors` の catalog fixture と rootless `make all` は通過した。これは曲一覧層のみで、端末の `-22` package に追加ゴールの製品変更は導入していない。同じ総曲数のままページ間で内容が変更された場合、現在の応答だけでは変更を検出できない。
- プレイリスト画面を一度だけ読取り専用で確認した。`DownloadButton.Granular.None` の TouchUpInside 所有者は `GranularDownloadButton -performAction` で、その `-uiView` は実 UIButton と同一 pointer。親の `MusicAppPageHostingViewController -URI` は正規 playlist URI 形状を返した。ボタン自身は enabled／interactive だが、`HeaderActionsRow` に arranged された祖先 `ListUXPlatform_FreeTierPlaylistImpl.ActionView` が hidden で、窓内 x=-44 にある。アルバムの「直近の親だけ表示」処理は適用しない。値を伏せた証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/playlist-native-owner-geometry-readonly.json`。
- 同じプレイリストで `ActionView.hidden` だけを一時的に解除した可逆UI試験では、`HeaderActionsRow` が92→140ptに広がり、ボタンは窓内 x=-44→4、兄弟はそれぞれ48pt右へ移動した。重なりなし、ボタン中心の `window.hitTest` は実ボタン、元の hidden と矩形への復元も確認した。アクション・保存APIは呼ばず、索引 SHAとWAV5件は不変。試験後はSpotify停止・Wi-Fi維持・X前面へ戻した。証拠は非公開 `Outputs/work/playplay-bulk-20261026/evidence/playlist-action-reveal-once.json`。これは**表示／タッチ配置だけ**の成立であり、一括保存の成立ではない。
- 通常再生1回に対する受動的な key-prefetch lineage probe は、対象 Spotify 9.1.88／UUID に一致し、呼出し1件・queue 要素選択1件を観測したが、導出 ID と provider 要求は0件だった。cache や条件分岐のどちらによる0件かは判定できず、任意未再生曲の鍵取得を示さない。index SHA と WAV5件は不変、再生停止後に元の前面アプリを復元した。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/normal-prefetch-lineage-one-album.json`。
- playlist Pathfinder の実機応答を、公開プレイリスト1件で値を出さずに検査した。HTTP 200、50項目すべて `Track`／正規 track URI、曲名50件、`artists.items[].profile.name` 50件で、現行 `OfflineCollectionCatalog.parsePage` の1ページ分の契約を満たした。別のローカル曲だけのプレイリスト13項目は `LocalTrack` で、同 parser は全体を `unsupportedItem` として拒否する。ローカル曲を Spotify 音源として誤って保存しないため、混在プレイリストも現状は一括対象にしない。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/pathfinder-playlist-two-pages-readonly.json` と `pathfinder-localtrack-playlist-case.json`。100曲超の実機ページ間整合性はこの回では測っていない。
- 公開5曲アルバムの先頭3件も、値を出さない Pathfinder 実機probeで HTTP 200、正規 track URI・曲名・`artists.items[].profile.name` が各3/3と確認した。これに基づき `Collection.tracks` に URI・title・artist を載せ、複数ページと重複の元順序を保持し、保存対象の `uniqueTracks` は最初の表示情報を採用する。欠落・不正表示名は完了前に拒否し、従来の単曲アルバム API は維持する。ホスト fixture は通過。実機の全ページ分のタイトル/アーティストと製品ジョブへの接続は未検証。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/pathfinder-album-metadata-readonly.json`。
- 別の受動 probe では、既知アルバム1回と公開プレイリスト1回の通常再生中に PlayPlay entry がそれぞれ1件／4件あった一方、`Prefetch: start prefetching track` 近傍の virtual `+0x20` 呼出しはどちらも0件だった。この実行条件で receiver 型と当該 virtual の PlayPlay 到達は判定できない。プローブは終了時に外し、index SHA／WAV5件は不変、Spotify停止・X前面へ戻した。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/prefetch-receiver-lineage-one-album.json` と `prefetch-receiver-lineage-one-playlist.json`。
- `SPTEsperantoPlayer` には context 再生と prepare の Objective-C selector があるが、公開プレイリストの通常再生1回を受動観測した範囲では対象9 selector は0件、PlayPlay prefetch entry は2件、provider 新規呼出しは0件だった。通常UIのその再生をこの ObjC API に帰属できず、prepare selector の存在だけで任意曲の非再生鍵取得経路とは扱わない。索引とWAVは不変。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/play-context-preparation-one-playlist.json`。
- Spotify 9.1.88 の静的解析では `core-prefetch-feature/prefetch_allow_all_keys_experiment` の getter が `Spotify+0x4964FEC` 付近で参照され、`prefetch-keys` が有効で、`key-caching-max-count >= 1` かつ `offline` または当該 flag が真の場合に限り、receiver の virtual `+0x68` へ mode 2 を渡す。条件を満たさない場合は mode 0／1。後続の具体的な receiver `+0x6E1B1D4` は mode を `+0x14c` に保存し、同 receiver が生成する scheduler はその mode に応じて head-file 先読み候補を cursor、次の1件、または適応 window 端の**1件**から選ぶ。従って mode 2 は候補位置に影響するが、全曲走査・全鍵取得の根拠ではない。ディスク上の max-count default 0 は実行時値ではなく、既存 ObjC `RemoteFlags` override がこの C++ getter に届くかも未特定。製品 flag は変更していない。詳細は git 対象外の `Outputs/work/playplay-bulk-20261026/notes/all-keys-prefetch-static-delta.md`。
- 上記 count／mode の受動観測 probe はホストの UUID・命令列 fixture を通したが、実機値は取得できなかった。spawn→attach 系の初回と再試行はそれぞれ Frida `TransportError`（再試行は `load_script`、保存済み JSON は再試行分）、続く launch→attach の1回は `script.load()` 後、最初の `status()` が `RPCException` となり `scriptErrors=1` だった。後者の callback はエラー本文を保存しなかったため、静的検査だけで gate 不一致と hook 登録失敗を一意に識別できない。いずれも通常再生タップ0、開始／終了の索引 SHA と WAV5件は不変、X 前面・Spotify 停止に復元した。`key-caching-max-count` と mode の**実行時値は未取得**であり、受動 probe は再実行していない。保存済みの値なし証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/core-prefetch-config-spawn-load-failure.json` と `core-prefetch-config-one-playlist.json`。
- 未再生鍵の独立要求に必要な非消費チェックとして、`ppkc_has_for_file_id()` を追加した。20-byte IDに帰属する未消費slotの瞬間的な有無だけをmutex下で返す。rootless/Gum fixture（不在、帰属なし、消費後、8枠追い出し）とrootless buildが通過した。端末導入済み `-23` には含むが、照会後の鍵保持や曲が未再生であることは保証しない。製品捕捉は8枠の最古世代を上書きするため、先読みした鍵が保存順まで残る保証もない。枠数だけ増やしても任意曲の鍵取得は解けず、平文鍵の保持期間とhook内走査コストが増えるので変更していない。
- disarmed provider trial の旧 load-only 実機確認では、callback ABI 自検は true、x8 bridge/CWork 自検は false で通常再生前に停止した。CWork の mode 0 を mode 7 の期待値と比較した fixture 不一致をホストで特定・修正した。**旧 JSON は同名での次回実行により上書きされ、独立ファイルとしては残っていない。旧結果の根拠は会話ログの読取出力のみ**である。修正後の1回では両 self-test が true、4つの実 provider review gate は false、通常再生中の provider 呼出しは0件だったため synthetic-only 投入には進まなかった。索引 SHA と WAV5件は不変、Spotify 停止・X前面復元を確認した。修正後の値を伏せた JSON は git対象外の `Outputs/work/playplay-bulk-20261026/evidence/disarmed-synthetic-only-fixed-bridge-1805.json`（0600）。
- 同一file-IDのHTTP応答→native 28-byte recordを照合する**初回 interrupted 試験**は、Fridaの生存中`session.detach()`で待機したためSIGINTで停止し、照合結果は得られなかった。端末は手動でX前面・Spotify停止に戻し、索引SHA/WAV5件不変を確認。この回自体を変換成立の証拠にはしない。記録は git対象外の `Outputs/work/playplay-bulk-20261026/evidence/playplay-transform-parity-interrupted.json`。
- 終了順序を Spotify process exit first に改め、Frida RPC を6秒上限・worker全体を110秒watchdogとした**v1受動試験**では、公開アルバムの通常再生1件で provider ID＝PlayPlay POST URL ID、HTTP 200 応答のfield1 16B＝handler入力16B、`fallback` tableからの非ゼロ28B出力＝success callback呼出し引数、call target＝owner success callbackを同一要求で確認した。ただし callback entry 内の capture/record 照合は probe の早期フィルタで観測できず、`sameFileTransformObserved=false`。これは**部分照合**であり、完全成立とは記録しない。証拠は git対象外の `Outputs/work/playplay-bulk-20261026/evidence/playplay-transform-parity-one-request.json`（0600）。
- 別の公開アルバムで実施した**v2受動試験**では、その早期フィルタを分離し、同一 handler frame 内の owner callback entry 1件を確認した。capture pointer＝provider側、callback capture ID＝同一要求 ID、callback 28B record＝handler出力はいずれも真。直接BLRの復帰位置との一致のみ偽であり、v1の未観測は return-site フィルタに起因するという解釈と整合する。別試料のため、v1個別回の原因までは断定しない。`sameFileTransformObserved=true` は**通常再生中の同一1要求についてHTTP field16→native 28B callback record の連鎖を値を出さずに照合した**ことを示す。独立に任意の未再生曲を要求するABI、16Bから28Bを単独生成する演算式、全曲一括保存、実ファイル保存・オフライン再生をこの2回の受動probeから導いたものではない。v1/v2とも X前面・Spotify process不在・索引SHA/WAV5件不変を終了後に独立確認した。証拠は git対象外の `Outputs/work/playplay-bulk-20261026/evidence/playplay-transform-parity-owner-v2-one-request.json`（0600）と `Outputs/work/playplay-bulk-20261026/notes/playplay-transform-parity-result-20261026.md`。
- 旧 YAD の16B鍵展開と native record 先頭16Bを比べる**v3試験**は、Frida Python RPC名と JavaScript export名の不一致で比較前に終了した。比較値が無いため一致・不一致いずれの根拠にも使わない。証拠は git対象外の `Outputs/work/playplay-bulk-20261026/evidence/playplay-transform-yad-same-request-one-album.json`（0600）。RPC契約を修正して別の公開アルバムで行った**v4一回試験**では、同一 owner 要求 ID＝POST URL ID、HTTP応答 field1 16B＝handler入力、`fallback` table、native 28B出力＝owner callback record がすべて真で、POST・handler・owner callback は各1件、hook error 0だった。この同一応答16Bと同一IDで旧 YAD `pp_unwrap` をアプリ内で実行し、self-test成功・演算 error 0の上で、その出力16Bと native record 先頭16Bの等値は**偽**だった。応答16Bそのものと native 先頭16Bの等値も偽。値は記録せず、bool/countだけを残した。これは**この Spotify build・fallback table・通常 format0 再生経路の1要求で旧 YAD 実装が native 先頭16Bを再現しない**という限定的な観測であり、全曲・全table・別formatの普遍的な不一致、native 28B末尾の意味、非脱獄IPAでのロード、任意未再生IDの取得・直接HTTPだけでの変換は示さない。watchdog正常終了後、X前面・Spotify process不在・索引SHA/WAV5件不変・一時診断dylib不在を独立確認した。証拠は git対象外の `Outputs/work/playplay-bulk-20261026/evidence/playplay-transform-yad-same-request-v4-one-album.json`（0600）。
- 一括保存の製品バックエンドは、全ページの重複なし曲を順次処理し、metadataで20-byte file IDを確定した後に同IDのPlayPlay鍵を非消費照会する。鍵がなければstorage/CDN転送前に曲別失敗、鍵があれば保存直前に同IDで消費する。開始・終了時の検証済みWAV索引、ジョブID付き協調中断、既定24時間期限、曲ごとの進捗、予定件数一致の完了判定を備え、手動中断と期限切れを区別する。プレイリストは全曲処理後に全出現順URIを再取得照合し、同件数編集・再取得失敗を`.partial`とする。ホストfixture、rootless `-23+debug` package、IPA用Internal/Gum backend debのビルドは通過。処理中1曲の通信・復号は中断後も終了まで続き、再取得中の同時編集を原子的に検出するserver revision契約は未確認。
- `-23+debug` を端末に導入し、Spotify 9.1.88で保存済み単曲アルバムのチェックマーク、多曲アルバムと公開プレイリストの純正スロット内Eevee保存ボタン、配置・非重複・hitTestを実機確認した。後者2つは全ページ取得から`OfflineDownloadCoordinator.download(collection:)`へ接続し、`.complete`と検証済みWAV全件の再読がそろう場合だけチェックを出す。部分失敗・期限切れ・中断・プレイリスト変更を全件成功と表示しない。**このUIスモークでは保存ボタンを押しておらず、多曲一括保存と通信遮断再生は未実証**。全曲の任意PlayPlay鍵取得も未確立。IPA用debのビルド成功は非脱獄注入IPAの実機動作を示さない。証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/product-ui-smoke-23-f3c368094a82.json`と`product-ui-smoke-23-dd42142bae1b.json`（0600）。
- 2曲の公開アルバム `Two Is One` では Pathfinder HTTP 200、異なる正規track URI 2件、純正Eeveeボタンの表示・有効化・hitTestを確認した。曲行 `Lev 1` を一意のAX/幾何で束縛して1回タップすると製品 `ppkc_generation` は1→2に増えたが、25秒内に `MPNowPlayingInfoPropertyExternalContentIdentifier` をアルバム1曲目URIへ結び付けられず、安全ゲートで停止した。両曲のformat-0 file IDと鍵slotは未照合、保存ボタン0回、元の索引SHA/WAV5件は不変。新規捕捉の増分は**その2曲の鍵が利用可能という証拠ではない**。値を伏せた0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/two-song-album-readonly-23-32b18fd4771c.json`と`two-song-album-row-proof-23-26549ccddff3.json`。
- ホスト回帰で、最終曲を処理している間に24時間期限を越えると、旧実装が `.complete` と返す不具合を再現した。最終結果の構築時にも絶対期限を確認し、保存済み曲を残して `.partial`／`.deadlineExceeded` とする最小修正とfixtureが通過。修正を含むrootless `7.0.0-24` を導入したが、読取り専用UIスモークでは公開プレイリストの `ActionView` が2–20秒間hidden、row幅198pt、hitTestがボタン以外だった。`-23` の同画面は表示中・row幅246pt・hitTest一致。AXはEevee表示のままで、native renderer再非表示後の再検査欠落と整合するが、その時刻・原因の直接traceはない。
- 既存の遅延 `prepare` で同一host/state/epoch/ownerのプレイリストbindingだけを再照合し、hidden時に既存の配置・非重複・hitTest gateを通して再表示する修正を加えた。rootless `7.0.0-25` とIPA/Internal backend debをビルドし、端末へ`-25`を導入。導入後の読取り専用スモークでは保存済み単曲チェック、多曲アルバム保存ボタン、公開プレイリスト保存ボタンを確認した。プレイリストは2/5/10/15/20秒すべてActionView表示中、row幅246pt、hitTest一致・兄弟重複なし。このスモーク単体では**回復分岐そのものの発動は未観測**。Spotify本体・元の索引SHA/WAV5件・X前面・Spotify不在は前後一致。0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/product-ui-smoke-24-87a9a55544cb.json`と`product-ui-smoke-25-94ebf1f41009.json`。
- `-25` の2曲アルバム追試では `SPTEsperantoPlayer` の状態更新から `Lev 1` の正規URI一致を確認した。旧試験の `MPNowPlayingInfoPropertyExternalContentIdentifier` 不一致は取得元の違いによる偽陰性であり、対象曲が再生されなかった根拠ではない。曲行タップ1回後、製品 `ppkc_generation` は1→2、両曲のmetadata HTTP 200と20-byte ID束縛が成立し、非消費 `ppkc_has_for_file_id` は **Lev 1あり／Lev 2なし**。JS診断は複数format-0候補の20-byte IDがすべて同じ場合だけIDを保持するが、製品resolverは最初のformat-0 IDを選ぶ。今回の値なし証拠では診断側の同ID検査が通り、製品バッチの全曲鍵保証はなお不成立。保存ボタン0回、索引SHA/WAV5件不変。0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/two-song-album-row-proof-25-2a35dc4803a7.json`。
- 同じ2曲アルバムで、両format-0候補のID同一性を再確認し、保存直前の鍵slotがLev 1あり／Lev 2なしの条件で純正Eeveeボタンを**1回**押した。製品バッチはpartial終端通知を表示し、index/WAVは5→6件でLev 1だけ追加、Lev 2は未保存。新規WAVは正規RIFF・3秒超でタイトル/アーティストが一致し、元5件のentry/WAV SHAは全件不変、一時ファイル0件。ボタンは再操作可能で全件チェック表示なし。これは**一括処理・曲別失敗・部分完了UIの実機証明**であり、全曲保存・2曲の通信遮断再生の証明ではない。0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/two-song-album-partial-proof-25-5eba41229423.json`。試験後は-25と両バイナリSHA、新しいindex SHA/WAV6件、X前面・Spotify不在、Wi-Fiと外部TCP復旧を独立確認した。
- 続く別プロセスの**2回目の操作**では、`Lev 2` 行を1回再生して `SPTEsperantoPlayer` の正規URI一致・新たな鍵捕捉・同IDの未消費鍵を確認し、純正Eeveeボタンを1回押した。既存Lev 1は索引から再利用され、終了後index/WAVは6→7件、Lev 2の正規RIFF WAV・3秒超・曲名/アーティストを確認し、以前の6件のentry/WAV SHAは不変、一時ファイル0件。保存中runnerの `tempCount<=1` が製品の encrypted/ogg/ogg.partial/wav の一時ファイル数を考慮せず `unexpected_store_write` と早期停止したため、**保存時のcomplete popupは未観測**。その後の別の読取り専用実機確認では、正確な2曲アルバムの純正Eeveeボタンが全件保存チェック・無効状態で、両正規URIが7件の有効WAVに一致した。旧証拠は保持し、runnerの一時ファイル条件は修正した。0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/two-song-album-completion-proof-25-be038fffd232.json`と`two-song-completion-ui-readonly-25-6c4b7acb1a92.json`。
- 通信遮断・外部TCP接続失敗を確認してからEeveeマイライブラリのLev 1/Lev 2各保存行を1回ずつ選択し、各曲でローカルプレーヤーsection・対象タイトル・再生位置sliderを2時点で確認、両方とも3秒超進行し再生エラーなし。index/WAV7件のentryと全WAV SHAは試験前後不変。終了後はWi-Fi/外部TCPを復元し、Spotify停止・X前面、-25と両バイナリSHA、7件validを5秒遅延の独立読戻しでも確認した。0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/two-song-offline-replay-25-27bf5a5f5970.json`。これで**既保存1曲＋新規1曲の2曲アルバム完成状態と端末内オフライン両曲再生**は実証したが、各曲を事前に別々に通常再生して鍵を得た条件付きであり、純正ボタンだけで未再生の任意全曲の鍵を自動取得する機能ではない。プレイリストの全曲実保存・通信遮断再生もまだ未実証。
- 既存providerの非atomic work vectorを共有せず、factoryから独立providerを得る候補をSpotify 9.1.88上で静的に特定した。ただしraw transport依存の生存期間、実行キュー、非同期workの解放、任意IDでの応答が未確認なので製品には接続していない。git対象外の`Outputs/work/playplay-bulk-20261026/notes/isolated-playplay-provider-factory-candidate.md`に境界を記録した。
- `-25` の公開プレイリストで ActionView だけを一時的に隠す可逆試験を1回行った。行幅246→198pt、ボタンhitTest真→偽の後、予定3秒の `prepare` 訪問と53ms差の時刻に `reconcileScheduledAppearance` とEevee由来 `setHidden(false)` が記録され、幅246pt・hitTest真・非重複へ戻った。これは**予定訪問との強い時間的帰属**であり、単独の呼出しを原因として直接証明するものではない。原ランナーは次回訪問を6秒と誤選択して `recovered_attribution_unconfirmed` としたため原証跡を保持し、端末再試験なしで派生判定を別記した。保存・再生操作0、索引SHA/WAV7件とアプリ本体は不変。0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/playlist-rehide-recovery-25-d3a539546759.json`と`playlist-rehide-recovery-25-derived-d3a539546759.json`。
- [公式公開2曲プレイリスト](https://open.spotify.com/embed/playlist/1InUDMyM4tQvwItEFCityY)のPathfinder実機応答はHTTP 200、playlist URI・2曲名・異なる正規track URI 2件と製品parserのartist schemaに一致した。公開embedとPathfinderのartist setは異なるため、厳密な表示クレジット一致とは扱わない。純正ボタンは2/5/10/15/20秒にActionView表示・hitTest成立。公開embedの2 URIと既存索引7件の交差はSSH読取り専用で0件と確認した。**このプレイリストの保存ボタン・全曲保存・通信遮断再生はまだ試験していない**。0600証拠はgit対象外の`Outputs/work/playplay-bulk-20261026/evidence/two-track-playlist-readonly-25-d8870679022f.json`と`public-playlist-index-overlap-readonly-6533938bf130.json`。前者runnerはURI交差RPCの命名ミスで最終stageがerrorだが、PathfinderとUIの個別観測値は有効であり、RPC名をホストで修正した。
- 非脱獄向けビルド入力の監査では、手元の`structural-fixture.ipa`は本体とplistの2エントリだけで、実機暗号化Mach-Oと`cryptid`の1バイト以外同一だった。これを実IPAと誤認しないため、`Tools/graft-ipa-playplay.sh --check-input`を9.1.88ビルドの最初に呼び、bundle構造・UUID・命令列と既知暗号4KiBページを拒否するホストテスト3件が通過。未知の暗号ページ一般への復号保証ではない。完全な9.1.88復号済みIPAおよび`cyan`/`ipapatch`が現ホストに揃わず、**実注入IPAの生成・署名・起動確認は未実施**。IPA/Internal backend debのビルドと区別する。

### 最新の実機結果と残る境界

- Spotify 9.1.88 の純正 `DownloadButton.Granular.None` をアルバムで確認。ボタンと親が非表示だった。ユーザープレイリストにも実体はあるが祖先の ActionView が非表示。アルバム／プレイリストとも、レスポンダーチェーン上の `MusicAppPageHostingViewController -URI` が対応する page URI を返した。既存の古い `downloadToggled...` selector は現行版にない。
- アルバムの純正ボタンは renderer `Spotify+0x26C2660` に渡される `flag5=1` で非表示・操作不可になる。`flag5=2` なら表示・操作可能だが、その値を作る権限／モデル条件とイベント購読先は未特定。純正ボタンを強制表示しても保存成立は示さない。
- 純正ボタンの TouchUpInside は ElementsKit `GranularDownloadButton -performAction` に接続され、その `tapAction` 閉包は親 `Element_UIKit.ElementView<Foundation.URL>` のイベント配送へ進む。非表示の 1 曲アルバム画面でこの action を一度だけ呼んでも、6 秒間に純正 offline manager の保存・解除 API と download upsell のタップ API は呼ばれなかった。この selector 自体を保存 API とみなさない。初期の解析記録は [`native-action-closure-trace.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/native-action-closure-trace.md)。
- その後、同じ非表示ボタンの一回限りの `performAction` を追跡し、ElementsKit のイベント配送から `DownloadManagerImpl : DownloadManager` の購読クロージャ `Spotify+0x532FD18` まで到達することを確認した。受信イベントの `flag5=1` は `flag5=2` の条件を満たさず、manager のメソッドを呼ぶ前に戻る。producer の内訳を二回観測すると gate aggregate は `1`、availability aggregate は `2`、最終 tag は `1` だった。Swift 型メタデータ上の `OperationGateStatus` は 1=`unavailable(isHidden: Bool)`、2=`open`。続く class/status 限定トレースでは、2件とも `UpsellGate=unavailable(isHidden:true)`、他の三つの gate は `locked` だった。従って非表示ボタンを単に露出してタップさせるだけでは純正保存に進まず、UpsellGate のみを変更しても他 gate が開くとは限らない。manager 分岐の最終動作は未実証。実測値は [`native-download-dispatch-gate.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/native-download-dispatch-gate.md) に整理した。
- 純正 `Spotify_OfflineEsperanto_Proto_OfflineClient` の静的解析では、witness `+0x28` が `AddDownload`、`+0x30` が `RemoveDownload` RPC に対応する。protobuf `DownloadRequest` は任意の `device`、単一の `uri`、`music_video_uris[]` からなり、呼出箇所は `URL.absoluteString` を `uri` に入れる。ただし、上記の実機イベントは gate で止まっており、RPC 実行、渡される URI の種類、アルバムから曲への展開、保存完了は観測していない。純正のアルバム／プレイリスト操作を現在の 1 曲保存へ置換すると対象範囲を偽るため行わない。根拠は git 対象外の [`native-offline-client-add-remove-static.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/native-offline-client-add-remove-static.md)。
- Now Playing と通常の楽曲行の型・AX では、単曲対象の純正ダウンロード開始 action は確認できなかった。楽曲行の `DownloadStatus`／バッジは状態表示で、開始 action とは別。検索楽曲行の read-only view probe でも可視 download control／custom action は 0 件だった。ただし試した長押しはメニューを開かず通常再生となったため、開いたメニュー内の全項目については未確認。再生を停止して元の前面アプリを復元した。対象範囲が一致する現在の操作は Eevee 独自の現曲ボタンである。根拠は git 対象外の [`native-per-track-download-control-20261026.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/native-per-track-download-control-20261026.md) と [`per-track-native-download-surface-live.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/per-track-native-download-surface-live.json)。
- 再生時の `Spotify+0x7F271A4` が暗号化 Vorbis を復号することを確認。同じ file ID の CDN 音源全 4,029,276 バイトを、アプリ内に保持した 28 バイトの鍵関連レコードと別コンテキストで直接復号した。先頭 167 バイトと末尾ゼロ 3 バイトを除いた 4,029,106 バイトの Ogg は 974 ページすべての CRC／連番／EOS を満たした。鍵、Bearer、署名付き URL は端末外へ出していない。
- 別曲の再生を 1 回だけ観測し、PlayPlay provider の vtable `+0x10`（実体 `Spotify+0x8FA7878`）を 3 回、PlayPlay POST を 3 件確認した。各 POST の URL 上の file ID は、プロセス内で保持した provider 要求 ID の集合に **3/3** 一致した。これは 1 対 1 の順序や別々の 3 ID まで示すものではない。同じ stream owner に結び付いた 1 件では、成功 callback の ID と要求 ID、28 バイト鍵レコードの setter 引数・owner も一致した。鍵・ID の実値は記録せず、件数と等値判定だけを [`provider-key-route-gates.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/provider-key-route-gates.json) に保存した。任意 file ID を未再生で要求する ABI はまだ確定していない。
- 後続の静的解析で、provider は control block 付き強参照ペア、`x8` の 16 バイト戻り値は鍵ではなく非同期 work handle の強参照ペアだと確認した。通常 owner は handle を `owner+0xA8` に移し、owner 破棄時に work→provider の順で解放する。独立の未再生曲要求には callback descriptor の管理と handle／provider の寿命、実行 queue、キャンセル境界が必要。値を出さない通常要求 lifecycle probe を用意したが、キャッシュ済みの一曲を一回再生した 25 秒の観測では provider 呼出しが **0 件**で、この回から callback／解放順は決定できなかった。キャッシュの消去や別曲の反復探索はしていない。設計と結果は git 対象外の [`provider-lifecycle-metadata-only-design.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/provider-lifecycle-metadata-only-design.md) と [`provider-lifecycle-normal-live.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/provider-lifecycle-normal-live.json) に保存した。
- 別の新規アルバム曲を通常再生した際には、provider 生呼出し 3 件のうち owner／20-byte file ID で選択した 1 件について、provider 復帰、`x8` work handle の `owner+0xA8` への移動、同一 capture の成功 callback 1 回、後続の work disposer／descriptor 破棄まで観測した。選択した一件では owner と callback の file ID が一致。未選択の 2 件、owner 側に残る handle の最終解放、timeout／cancel、未再生 ID の独立呼出しは未証明。`providerStrongRelease` は共有 control block のため選択要求固有とは断定しない。結果は git 対象外の [`provider-lifecycle-normal-newalbum-live.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/provider-lifecycle-normal-newalbum-live.json)。
- PlayPlay HTTP 200 応答 handler の静的解析で、16-byte 難読化フィールドから VM 型処理を経て 28-byte レコードを成功 callback に渡す経路を特定した。別の 4-byte フィールドは callback へ別引数として渡る。閉じた 16→28 byte の演算式と安全に単独呼出しできる ABI は未確定で、provider が選ぶテーブルと async work の寿命も必要。16-byte 応答だけで任意曲のレコードを作れるという結論にはしない。根拠は git 対象外の [`playplay-record-transform-callgraph-20261026.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/playplay-record-transform-callgraph-20261026.md)。
- 独立 callback の事前確認用に、provider 呼出し・通信を含まない CModule self-test を用意し、ホストの C コンパイルと状態機械テストを通した。初回は Spotify が背景にある状態で Frida `attach` が `TransportError` となったが、Spotify を前面にして同じ接続経路で再試行すると attach と script load が通った。CModule の TinyCC で使えない `__atomic_*` builtins を libSystem の `OSAtomic*Barrier` 呼出しへ置き換え、端末上の synthetic callback／pair counter、arm64 `x8` 16-byte indirect-result bridge を、実 provider と通信を呼ばずに検証した。通常再生の実 provider pair では、強参照の増減を均衡させた一件の retain/release を観測した。これらは独立の実 provider 呼出し成功を意味しない。根拠は git 対象外の [`detached-provider-callback-preflight-foreground-v4.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/detached-provider-callback-preflight-foreground-v4.json)、[`indirect-result-bridge-foreground.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/indirect-result-bridge-foreground.json)、[`provider-pair-retain-parity-normal.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/provider-pair-retain-parity-normal.json)。
- provider の非同期 work vector `provider+0xA8` は非 atomic な共有配列で、通常の `+0x10`／`+0x18` の追加と `+0x20` の列挙・消去が競合し得る。通常再生ではこれらが同じ queue pointer 上で実行されることを確認し、その queue に synthetic callback だけを送って正常復帰・同 queue pointer・group fence を確認した。ただし queue の排他／直列性、実 provider の callback 終了、timeout 後の安全な script unload は未証明。Frida RPC thread から provider を直接呼ばず、任意 file ID の実 provider 試験は保持する。根拠は git 対象外の [`provider-queue-parity-raw-normal.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/provider-queue-parity-raw-normal.json)、[`captured-queue-synthetic-normal-v2.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/captured-queue-synthetic-normal-v2.json)。
- 通常のアルバム先頭曲の再生では provider `+0x10` が 3 回あり、1 件は active playback owner の file ID、別の 2 件は active ID と異なり、両方の呼出元は `Spotify+0x11FF208` だった。静的解析では、この呼出元は `w2=2` で provider を呼ぶ鍵 prefetch routine 内にある。この段階では、2 件が具体的にどの曲かは未特定だった。別の単曲検索結果からの再生では provider 呼出しが 1 件、キャッシュ再生では 0 件だった。根拠は git 対象外の [`provider-active-owner-caller-offset-normal-album.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/provider-active-owner-caller-offset-normal-album.json)。
- 別の通常アルバム再生で、同じ非 playback の prefetch 2 件がそれぞれ成功 callback に到達した。両件とも要求／capture／cache object の 20-byte ID 等値、28-byte レコードの読み取り可能・非ゼロ、アプリ自身の stale-ID guard 通過、内部 key-cache insertion からの復帰、`x8` work pair の object への移動と disposer 到達を値なしで確認した。これは**アプリの一時的な鍵 cache への挿入**であり、Eevee の保存索引やオフライン再生、対象 track URI と ID の対応を示さない。この観測時点で導入済みの製品版は playback setter のみを捕捉していた。根拠は git 対象外の [`provider-prefetch-callback-normal-album.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/provider-prefetch-callback-normal-album.json)。
- [Spotify 公式 Blue Train album](https://open.spotify.com/embed/album/2Z11cXWEa2qqYQBGkJrCga) の正確な album URI を端末の page controller で照合し、先頭曲の通常再生中に生じた prefetch 2 件の ID を、同じプロセス内でアルバム先頭 4 曲の format-0 metadata ID と比較した。4 候補すべての metadata が検証に通り、対応は `[再生中:なし、2曲目:slot0、3曲目:slot1、4曲目:なし]` で曖昧さなし。**このアルバムの次の2曲**への通常の鍵先読みを実証したが、製品による先読みレコードの捕捉、暗号化ファイルとの直接復号、未再生曲の保存・オフライン再生は別の合格条件。ID・鍵・Bearer はホストへ出していない。根拠は git 対象外の [`prefetch-candidate-equality-blue-train-live.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/prefetch-candidate-equality-blue-train-live.json)。
- Spotify 9.1.88 の UUID・命令列で限定した prefetch 鍵レコード捕捉を追加した。rootless は成功 callback から共有 cache helper に入る呼出元・mode 2 を照合し、helper 復帰後に 20-byte ID と 28-byte record を既存の8枠索引へ保存する。IPA/Gum は同じ callback の BL 呼出し点を probe するため、アプリ側の stale-ID・非ゼロ検査後かつ helper 実行**前**にその入力を記録する。ホストテスト・独立監査を通した rootless `7.0.0-16+debug` を実機に導入し、[Spotify 公式 Random Access Memories album](https://open.spotify.com/embed/album/4m2880jivSbbyEGAKfITCa) の未再生先頭曲を通常再生した。native prefetch 要求／成功 callback／非ゼロ record／stale-ID guard／cache helper 復帰は各2件、製品 `ppkc_generation()` の増分は3、probe errorと直近 crash は0だった。保存索引の SHA-256 とWAV 3件は不変。これは自然先読みと製品捕捉の件数相関であり、2件それぞれの exact-ID 消費や未再生曲の保存・オフライン再生は未証明。IPA 上の実行時動作も未検証。値なしの証拠は git 対象外の [`product-prefetch-generation-random-access-memories-live.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/product-prefetch-generation-random-access-memories-live.json)。
- 未再生の公開 track URI について、既存アプリの Bearer をプロセス内だけで再利用した extended-metadata POST は HTTP 200／内部 status 200 で、format-0 の一意な 20-byte file ID をプロセス内に保持できた。鍵取得や暗号化 asset の全量取得はこの試験には含まれない。RPC 診断へ Bearer、file ID、CDN URL は出していない。根拠は git 対象外の [`unplayed-target-fileid-process-only.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/unplayed-target-fileid-process-only.json)。
- 同じ未再生 URI の最初の Frida staging probe は、JS 製 `NSURLSession` delegate 経路で Spotify を二度終了させた。各回の後にアプリを再起動して UI と保存索引の不変を確認し、probe の一時部分ファイル 2 件を削除した。そこで delegate を使わない `NSURLSessionDownloadTask` の Range 経路へ変更し、再試行では metadata 200、storage-resolve 200、CDN 206／全体を表す Content-Range、同一 file ID 結合、暗号化 asset **2,857,052 bytes** の端末内 staging と 0600 権限・サイズ検証に成功した。試験ファイルは明示的に削除し、前面アプリを復元した。これは**未再生 ID の鍵取得・復号・再生の証明ではない**。delegate 版の寿命問題は未解決のため再利用せず、delegate-free 版にもリダイレクトの事前拒否と転送中の厳密な一時ディスク上限はない。値や private crash report を含まない証拠は git 対象外の [`unplayed-target-encrypted-stage-live-v3.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/unplayed-target-encrypted-stage-live-v3.json)。
- 後続の製品経路では、[Spotify 公式 Thriller album](https://open.spotify.com/embed/album/2ANVost0y2y52ema1E9xAZ) の1曲目を通常再生し、未再生・未保存の2曲目「Baby Be Mine」を固定した debug 専用ワンショットから保存した。自然 prefetch 成功2件、製品世代差3を確認した上で、ワンショットの終了状態は `2=保存成功`。独立索引は3件から4件になり、対象 WAV は **45,928,980 bytes／260.368秒**、RIFF・索引サイズ一致、一時ファイル0。Spotify 再起動後に Wi-Fi 外部経路なし・外部 TCP `errno=51` のまま独立ライブラリから再生し、約5.156秒まで進行した。証拠は git 対象外の [`product-unplayed-save-17.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/product-unplayed-save-17.json) と [`product-unplayed-offline-replay-17.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/product-unplayed-offline-replay-17.json)。初回 `-17` 起動時には diffable data source 付近の SIGABRT が1件あり、二回目の起動から保存・オフライン再生までは新たな crash なし。秘密値を含み得る crash report は非公開の 0600 ファイルで保持する。試験後、端末は debug 専用入口のない `-16` に戻し、4件の索引・対象行の維持を確認した。これは**固定アルバムの次曲1件**の proof であり、任意 URI、アルバム一括保存、純正ボタン／純正ライブラリの保存状態、非脱獄 IPA 実行の proof ではない。
- この Ogg を iOS で PCM16 WAV に変換し、Spotify 再起動後、Wi-Fi 外部経路を切った状態でアプリ内ローカル再生と 120 秒地点への seek を確認した。これは **Spotify 純正キュー／ライブラリ再生ではなく AVAudioPlayer の再生**である。
- 実 `SPTPlayerTrack.URI()` と一致する曲について、純正 `SPTOfflineManagerImplementation.makeEntityAvailableOfflineWithURL:` を一度だけ呼んだ。60 秒間 `availability=0`、`state=0`、関連キャッシュ容量も不変であり、純正保存は成立しなかった。
- 製品側には metadata/CDN resolver、Mach-O UUID で限定した復号器、Ogg→WAV 変換器、URI 索引、再生画面の現曲保存ボタン、独立オフラインライブラリを追加した。マイライブラリのヘッダーには独立ライブラリ入口を、メインのスクロール面には Eevee 管理の保存曲行を表示した。**未再生曲の任意 file ID の鍵取得、アルバム／プレイリスト一括取得、Spotify 純正保存状態との統合、非脱獄IPA上の実行時鍵捕捉は未実証**。
- マイライブラリの標準チップ列は `UICollectionView` 管理で、実機の `contentSize` は 349×27 pt、可視チップはプレイリスト／アルバム／アーティストの三つだった。独立した Eevee 保存済み項目をチップ列へ `addSubview` だけで追加しても項目数・スクロール幅は増えない。純正フィルター状態も独立 WAV 索引とは異なるため、標準チップは改変せず、44 pt の Eevee ヘッダー入口を維持する。
- マイライブラリ本体の既存行を一度タップし、`YourLibraryContentViewBinder` の選択 handler→Swift event helper→`MusicAppPageHostingViewController` の画面遷移を各 1 回観測した。行数・表示・選択・ドラッグは `YourLibraryModel.content.sections[].items` を共有し、`YourLibraryEntityType` に単曲 case はない。モデルに合成 cell を挿入する方式は採らず、Eevee の独立索引で検証した WAV の行だけを `YourLibraryCollectionView` のスクロール領域に別 view として配置した。Spotify の datasource／項目数／純正ダウンロード状態は変更しない。行の読取りは専用 queue、再読込は世代番号で古い結果を破棄し、表示は最大100行と「すべて表示」入口に制限する。根拠は git 対象外の [`native-library-row-event-one-tap-v2.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/native-library-row-event-one-tap-v2.json) と [`native-library-native-item-integration-20261026.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/native-library-native-item-integration-20261026.md)。
- rootless `7.0.0-18+debug` を Spotify 9.1.88／iPhone 12 mini に導入した結果、スクリーンショットでマイライブラリの Eevee 保存曲4行を視認した。Frida の読取専用 geometry は、保存曲 section `0,-260,375,260`、collection の上 inset `260`、offset `-260`、純正可視 cell 5件を返した。Wi-Fi の外部経路と外部 TCP を遮断した後に Spotify を再起動して同じ geometry と4行を再確認し、画面座標 `(120,214)` の先頭行をタップすると対象曲の独立ローカル画面が開き `AVAudioPlayer` が自動再生した。スライダーは **1.233→4.835秒**、外部 TCP は前後とも `errno=51`、索引 SHA-256 `9d0958d1fffe1f8f562590163c589c5aa0399153e4373afb9a66360078879942` と WAV 4件は不変。再生停止、Wi-Fi と元の前面アプリの復元を確認した。これは **Eevee 行からローカル WAV をオフライン再生した proof** であり、Spotify 純正キュー／純正ダウンロード行ではない。証拠は git 対象外の [`native-inline-18-screen.jpg`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/native-inline-18-screen.jpg)、[`native-inline-18-geometry.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/native-inline-18-geometry.json)、非公開 0600 の [`inline-library-offline-18-private.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/inline-library-offline-18-private.json)。
- `-18` では Eevee のヘッダー入口は AX 木に出る一方、4行は直接 view に label／button trait があっても `UICollectionView` の AX 列挙に現れなかった。ヘッダーからアクセス可能な全曲リストは維持するが、**inline 行そのものの VoiceOver 操作は未実証**。さらに section 初期幅0の時に flexible-width 行を追加したため、Frida 上の先頭行幅が collection 375pt に対して 750pt だった。section 幅を先に確定する修正を `7.0.0-19+debug` としてホスト build したが、**この `-19` は端末に未導入**で、幅修正の実機確認は次の統合 build の検証事項である。
- rootless `7.0.0-20+debug` を同じ Spotify／端末へ導入し、`-19` の幅修正が実機で **375pt** の行として反映されたことを Frida で確認。純正の既存プレイリスト行も選択・戻る操作が成立した。Votify の固定 `getAlbum` persisted query を、アプリ内の同一リクエストで得た Bearer／Client-Token の組で呼ぶ経路は HTTP 200、アルバム URI 一致、曲数1の応答を得た。純正 `GranularDownloadButton -uiView` と `DownloadButton.Granular.None` は同一 UIButton で、元の `-performAction` 配送先は `DownloadManagerImpl` 側の gate で止まるため、**曲数1と曲 URI の完全一致が確認できたアルバムに限って**ボタンを表示し、Eevee の1曲保存へ配送する。多曲アルバムとプレイリストの一括保存は実装していない。
- 公開の単曲アルバム「OPEN」（Slow Magic）では `-20` の純正ボタンが48×48ptで表示・操作可能となり、通常の再生後に **ボタンを1回だけタップ**した。`ppkc_generation` は1→3、Eevee 索引は4→5件、WAVは4→5件になり、新規ファイルは URI・RIFF/WAVE・44-byte header・data長・保存byteCountの検査に合格した。一時ファイルは0件。成功ポップアップを観測し、Spotify再起動後の同アルバムでは保存済みラベル・押下無効を5回の読み取りで確認した。ただし `-20` の画面では純正 Lottie が上に重なり、アイコンは矢印のままだった。これは独立WAV索引に基づく表示であり、Spotify純正 offline DB／ダウンロード済みフィルターを書き換えた結果ではない。証拠は git 対象外の `evidence/native-one-track-action-20.json`、`evidence/native-product-status-20.json`。
- 同じ新規保存曲を **Spotify再起動後、Wi-Fi外部経路なし／外部TCP `errno=51`** で検証した。マイライブラリの Eevee 行は5件、section `0,-316,375,316`、上 inset316／offset-316。索引内で URI 順2番目にある「OPEN」の行をタップすると独立ローカル画面が開き、`AVAudioPlayer` の位置は **0.989→4.596秒** に進んだ。索引 SHA-256 `38baf2609e01b806c8acfd4895edc0466fe55b9bacb61c65a84c8aff8c7309e6` とWAV5件は不変。Wi-Fi、X前面、Spotify停止を復元した。証拠は非公開 `evidence/native-one-track-offline-replay-20-private.json`。非脱獄注入IPAはユーザー指定により端末試験していない。
- `-21` で `UIButton.Configuration.image` のチェックマークは設定できたが、純正 Lottie が上に残って矢印を描いた。`-22` では曲数1と保存済み索引の検証に成功したボタンに限って、その Lottie view を隠し、画面上の緑のチェックマーク・保存済み AX ラベル・押下無効を実機で確認した。元の view 表示状態は画面離脱時に戻す。証拠は非公開の `evidence/native-action-saved-album-private-22.jpg` と `evidence/native-action-saved-visual-22.json`。同じ `-22` で通信遮断・Spotify 再起動後、マイライブラリの保存曲5行から「OPEN」のローカル再生が **1.251→4.846秒** に進み、外部 TCP `errno=51`、索引 SHA と WAV 5件は不変だった。Wi-Fi、X 前面、Spotify停止を復元した。証拠は非公開 `evidence/native-one-track-offline-replay-22-private.json`。

### 製品経路での 1 曲保存・オフライン再生

rootless deb `7.0.0-5+debug` を iPhone 12 mini に導入し、Spotify 9.1.88 の再生画面に表示した `EeveeOfflineCurrentTrackSave` をタップした。再生時に捕捉した鍵の世代は 1。アプリ内の通信取得→直接復号→WAV 変換→保存で完了ダイアログが表示され、`Application Support/EeveeSpotify/Offline` に 47,745,644 バイトの WAV と `index.json` が作成された。Eevee 設定の独立ライブラリに 1 曲が表示された。

Spotify を停止し、Wi-Fi 外部経路なし・携帯通信経路なし（外部 TCP は errno 51）で起動し直した。同じ独立ライブラリの曲を `AVAudioPlayer` で再生し、再生位置約 3 秒を確認。スライダーを約 122 秒へ動かした後、約 128 秒まで進んだ。ローカル再生を一時停止し、Wi-Fi 外部経路を復元した。この検証中の Frida／SSH／icli は**操作と観測用**であり、製品の保存・復号・再生処理には含まれない。曲名・URI・鍵・token は証拠 JSON に記録していない。詳細は git 対象外の `Outputs/work/playplay-offline-20261026/evidence/product-one-track-offline.json`。

当時の rootless deb `7.0.0-8+debug` でも再検証した。マイライブラリの新アイコンは 44pt の当たり判定で表示され、タップで保存曲 1 件の独立ライブラリへ遷移した。再生画面から同じ曲を再保存すると、WAV 1 件・索引 1 件が維持された。保存ディレクトリにはバックアップ除外属性が付いた。通信経路なし・外部 TCP errno 51 で Spotify を再起動した後、ライブラリから再生位置約 3 秒を確認し、約 124 秒へ seek 後約 128 秒まで進んだ。再生停止・Wi-Fi 再接続を確認し、検証前に前面だったアプリを復元した。新 UI と再生の証拠も同じ git 対象外 JSON に追記した。

鍵レコードを選択音源の **20-byte file ID に完全一致**させる変更では、`7.0.0-9+debug` の初回実機保存が「先に再生」のエラーになった。鍵世代は増えていたが未帰属で、原因は通常の PlayPlay 成功 callback を通らずキャッシュ済み／provider レコードを再適用する setter 経路だった。Spotify の wrapper 保存 SP/LR、stream owner、crypto context、レコード status と owner state を実機で照合し、再適用元の `owner+0x160` と製品 resolver の file ID が一致することを値を出さずに確認した。`7.0.0-10+debug` で status 2 の曲を保存し、独立ライブラリから通信遮断・再起動後に再生位置約 5 秒まで進むことを確認。続く `7.0.0-11+debug` では正常再生の status 1／state 3 も正規の再適用経路として属性付けし、別の 1 曲を保存した。WAV 3 件・索引 3 件を確認後、外部 TCP `errno=51`、Wi-Fi 外部経路なしで Spotify を再起動し、新しい保存曲をライブラリからローカル再生した。再生操作と 3 秒後に一時停止コントロールを確認し、スライダーは約 5.1 秒へ進んだ。プレーヤー停止、Wi-Fi 経路と元の前面アプリの復元も確認した。Frida／SSH／icli は観測・端末操作にだけ使用した。鍵・file ID・Bearer・署名付き URL は証拠へ出力していない。詳細は git 対象外の [`replay-fileid-attribution.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/replay-fileid-attribution.md) と [`product-fileid-replay-11.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/product-fileid-replay-11.json)。

`7.0.0-12+debug` では削除処理を、WAV の同一ディレクトリ内 tombstone 移動→索引更新→tombstone 削除の順に変更した。索引更新前の中断なら次の読み込みで WAV を復元し、移動失敗なら索引を変更しない。ホスト単体テストと rootless パッケージビルドに成功した。実機導入後、既存 WAV 3 件・索引 619 bytes と索引 SHA-256 が導入前後で同一だった。Wi-Fi 外部経路なし、外部 TCP `errno=51` で Spotify を再起動し、マイライブラリ入口から既存の保存曲を再生した。3 秒後もローカル一時停止コントロールがあり、シーク位置は約 5.1 秒、再生エラー表示なし。保存済み曲の**再生回帰**であり、この版で新規ダウンロードや削除の実機操作を再実証したものではない。Wi-Fi と元の前面アプリを復元した。証拠は git 対象外の [`product-offline-replay-12.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/product-offline-replay-12.json)。

`7.0.0-15+debug` では再生中の 1 曲ボタンを保存済み索引と連動させた。検証済み WAV がある URI はチェックマーク・保存済みアクセシビリティラベル・押下無効を表示し、未保存 URI は保存可能とする。状態確認をバックグラウンドで行い、確認中は押下を止め、曲変更や索引更新で再照会する。実機では未保存曲の保存可能表示、保存済み曲の押下無効表示、Spotify 再起動後の保存済み表示維持を確認した。通信遮断下でも外部 TCP は `errno=51`、マイライブラリ入口から既存 WAV を再生して 3 秒後の再生継続と約 5.1 秒への進行を確認し、Wi-Fi と元の前面アプリを復元した。これは**既存曲の再生・表示回帰**であり、この版で新曲の保存や削除を端末上で行った結果ではない。ホストの索引・通知テスト、PlayPlay 関連テスト、rootless deb と IPA 用 backend deb のビルドを実施。証拠は git 対象外の [`product-offline-replay-15.json`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/evidence/product-offline-replay-15.json)。

同じソースで IPA 用 Internal backend / Gum の deb も再ビルド済み。これは注入用成果物の静的ビルド確認であり、非脱獄端末・実 IPA での鍵捕捉、保存、再生の実証ではない。

保存は **Spotify 純正のダウンロード状態／キュー／マイライブラリの保存済みフィルターではない**。-22までの再生画面Eevee現曲ボタンと単曲アルバム純正ボタンに加え、-23では多曲アルバム／プレイリストの純正ボタンをEevee独立索引の一括保存へ接続し、表示・配置だけを実機確認した。IPA用 Internal backend／Orionランタイムは現行ソースでローカルビルド済み。脱獄用 `MSHookFunction` の代わりに、IPA用にはFrida Gumのcall-site probe、署名前graft、chained-fixups修復を実装した。完全復号済みSpotify 9.1.88 IPAから、純正Info.plistと最低OS 16.1を保持し、標準appex／Watchを除去した**未署名の注入IPA**をホストで組み立てた。ZIP整合性、全残存Mach-Oのcryptid 0、ロードコマンドと2箇所のgraft、dyld検証、隔離コピーでのad-hoc再署名検証は通過し、独立レビューも合格した。元IPAとローカル成果物はgit対象外・非公開のまま保持。実developer署名、非脱獄端末へのインストール、鍵捕捉・保存・再生は未検証であり、ユーザー指定どおり非脱獄IPAの実機テストは行っていない。依存とライセンスは [`frida-gum-dependency.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/docs/frida-gum-dependency.md) に記録した。

実機の直接復号と readback は [`direct-ogg-proof.md`](/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/playplay-offline-20261026/notes/direct-ogg-proof.md)、UI の隠れた純正ボタンは `Outputs/work/playplay-offline-20261026/evidence/ui/`、純正 manager の一度の呼出しは `evidence/native-offline-one-invocation.json` に保存した（いずれも git 対象外）。以下の「PCM 保存」「未特定」等の記述は**直接復号に成功する前の調査時点**を記録している。

## 目標と実装範囲

- iPhone 単体でダウンロード・保存・オフライン再生を完結させる。
- 非脱獄環境でも、署名済み IPA に必要な dylib／framework を注入して利用する。
- 純正のダウンロード操作とライブラリ表示を利用し、別のダウンローダー画面を必須にしない。
- Frida、SSH、icli は調査用。通常利用にサーバー、SSH、root、Frida を要求しない。
- 実際に保存・検証したファイルだけを「ダウンロード済み」と扱う。

## 実機で確認したこと

以下は初期調査時点の記録。対象は接続中の iPhone 12 mini（iPhone13,1）、iOS 17.0、Spotify 9.1.88（918802209）。EeveeSpotify の deb 7.0.0 が導入済みで、Spotify プロセスに `EeveeSpotify.dylib` と `EeveeSwiftProtobuf` がロードされていた。この初期調査では deb の再インストールは行っていない。

Frida は USB ポート転送経由で接続。クライアント 17.19.0／端末サーバー 17.24.3 の組み合わせで、native runtime のメタデータ取得に成功した。全機能のバージョン互換性を確認したという意味ではない。

### 旧 selector の hook は現行実機に適用されない

`Sources/EeveeSpotify/Premium/ServerSidedReminder.x.swift` は以下のクラスをフックし、説明ポップアップへ置き換える実装を持つ。

```text
Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation
```

実機ではこのクラス自体は存在するが、以下の両 selector は、継承メソッドも対象にする `class_getInstanceMethod` で取得できなかった。

```text
downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:
downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:
```

superclass は `NSObject`。own instance methods は `init` と `.cxx_destruct` のみだった。既存の `activateV91ServerSidedReminderIfAvailable()` は selector guard を持つため、これを前提に新 downloader を呼ぶだけの変更では、現行版の操作につながらない。

### 状態とライブラリのクラスは存在するが、接続仕様は未確定

| クラス | 実機の own Objective-C instance methods |
| --- | --- |
| `Download_StateImpl.DownloadManagerImpl` | なし |
| `Download_StateImpl.DownloadStateServiceImpl` | dependency injection、init、destructor |
| `Offline_DataModelImpl.YourLibraryDownloadsDataSource` | なし |
| `Offline_DataModelImpl.OfflineDataSourceImplementation` | なし |
| `LocalFiles_CoreImpl.LocalFilesAPIService` | dependency injection、settings provider、unload、init、destructor |
| `SPTEsperantoPlayer` | `playContext:options:`、seek、queue、observer などが存在 |

own Objective-C methods がないことは、Swift の処理や protocol witness がないという意味ではない。`playContext:options:` の存在も、任意のローカル音源を Spotify の楽曲 URI として再生できる証明ではない。

追加で helper、manager、2 種の data source の Swift metadata／vtable を読み取ったところ、各 vtable は initializer descriptor 1 件のみで、live slot はいずれも `swift_deletedMethodError` を指していた。ダウンロード操作に対応する関数は特定していない。共通の Swift runtime 関数や未知の slot を推測でフックする変更は行っていない。

icli でライブラリ、お気に入りの曲、プレイリストとそのメニューを確認した。当時の可視 UI にはダウンロードボタン／メニュー項目がなかった。後続の UI 階層調査で、アルバムとプレイリストには純正ボタンの実体が存在し、祖先の表示状態によって隠れていると判明した。プレイリストの編集・削除、全曲音源のダウンロード、設定の変更は行っていない。

## Votify から再利用する部分

調査した Votify は [commit db14e4d](https://github.com/glomatico/votify/tree/db14e4d1aa01456e0ec3b55d6f7268787ba2e2c4)（1.9.9）。その構成は次のとおり。

```text
URI / media ID
  → metadata と品質を解決
  → file ID / CDN / 音源鍵を解決
  → 一時ファイルに取得
  → 復号・形式処理・タグ付け
  → 最終ファイルと独立した索引
```

Votify の任意 SQLite は `media(id, path)` という独立した索引で、Spotify 純正のオフライン DB を更新するものではない。純正ボタン、進捗、ライブラリ、再生 resolver の実装は含まれない。[保存処理](https://github.com/glomatico/votify/blob/db14e4d1aa01456e0ec3b55d6f7268787ba2e2c4/votify/downloader/audio.py#L225-L278)、[SQLite](https://github.com/glomatico/votify/blob/db14e4d1aa01456e0ec3b55d6f7268787ba2e2c4/votify/cli/database.py#L5-L43)

Python CLI 全体の同梱ではなく、URI を共通キーにする設計、品質解決、取得と最終保存の分離を再利用する。認証情報・鍵・CDN URL を含む上流の DEBUG logging は移植しない。また、上流 CLI は例外時にも `finally` 内の索引更新に到達するため、統合側では「取得成功・ファイル検証・最終配置」の後だけ完了を公開する。[上流の完了処理](https://github.com/glomatico/votify/blob/db14e4d1aa01456e0ec3b55d6f7268787ba2e2c4/votify/cli/cli.py#L233-L263)

## iPhone 単体と非脱獄への対応方針

保存先はアプリ sandbox の専用 `Application Support` ディレクトリとし、ライブラリは独立した URI 索引で持つ。既存 `OfflineHelper.resetData()` が削除する `PersistentCache`、`remote-config`、`Caches` とは分離する。ただし `FullResetHelper.wipeSpotifyState()` は `Library`／`Application Support` の子も削除するため、保存曲が消える操作として製品 UI に明示する。純正 DB への直接書き込みや、account entitlement に保存状態を混ぜる方式は採らない。

通常利用は既存の IPA 注入経路に統合する。`build-ipa-local.sh` は deb 内の dylib、bundle、framework を IPA に注入し、`zxPluginsInject` を加える経路をすでに持つ。ただし、今回の実機は脱獄環境であり、新機能の非脱獄動作を確認したものではない。

### 既存アプリ内セッションからの取得を実測した結果

アプリ内に存在する通常楽曲の URI と、通常のリクエストに使われている Authorization／client token をプロセス内で保持した。URI、token、音源鍵、署名付き CDN URL はホストへの RPC 診断に含めていない。サンプル URI は live track object から選択したもので、常に現在再生中の曲を選ぶ製品用 resolver の実装ではない。

| 段階 | 実測結果 | 解釈 |
| --- | --- | --- |
| 旧 metadata GET | HTTP 200、JSON parse 成功。`audio_formats` があり、旧来の `file` 配列はない | 旧 JSON の `file` 前提をそのまま移植しない |
| extended-metadata POST | HTTP 200。TRACK_V4／AUDIO_FILES の provider status と inner status も 200。URI 一致、audio file 5 件 | 現行 protobuf 経路で file ID の解決が成立 |
| client token を省いた POST | 既存 Bearer だけでも HTTP 200／inner 200、audio file 5 件 | この実機・セッション・endpoint では client token は必須ではなかった |
| storage-resolve | Bearer＋client token、Bearer のみの両方で HTTP 200、CDN URL あり | 音源 URL まで既存認証を再利用できる |
| CDN Range GET | Authorization／client-token を付けずに HTTP 206、4,096 bytes、Range が有効 | 音源ファイルの一部取得が成立。全曲取得や復号の成功ではない |
| AP resolver／接続 | HTTPS 200、通常の TLS 検証成功、TCP 接続成功、固定公開鍵によるサーバー署名検証成功 | ネットワーク未到達や署名検証省略による結果ではない |
| AP TOKEN login | APWelcome なし、error 11 `PremiumAccountRequired` | この Python librespot 互換 profile では音源鍵取得へ未到達 |

AP 認証は一回だけ行い、応答後すぐ接続と短命プロセスを終了した。`BadCredentials`（12）や `ApplicationBanned`（17）とは別の enum だが、この一回の応答から、別 client identity／別アカウント／iOS アプリ自身の認証まで一般化しない。[上流の error enum](https://github.com/kokarare1212/librespot-python/blob/acd633d3eb26f7b61b21e5049cabb236b8f1298e/librespot/proto/Keyexchange_pb2.py#L502-L506)

AP 計測は iPhone 内の一時 Python probe に、アプリから loopback の一回限り HTTP で token を渡す方式。token を Mac に渡したりファイルへ保存する経路はない。HTTPS 証明書検証、署名付き DH、Shannon MAC の検証を維持し、ログは status／bool／error enum だけに限定した。これは調査用の構成で、製品に Python／SSH／Frida を要求する設計ではない。

### iOS PlayPlay 応答と 1 曲のローカル再生

アプリを Frida spawn で再起動して通常楽曲を再生し、iOS ネイティブ通信を観測した。PlayPlay のリクエストは `__NSURLSessionLocal`／`SPTCoreURLSessionDataDelegate` を通った。応答は HTTP 200、24 bytes の protobuf で、field 1 に 16 bytes の `obfuscated_key` が存在した。鍵の値は外へ出していない。通常再生時に PlayPlay が機能することは確認できたが、難読化キーから AES 音源鍵への iOS 側の展開関数はまだ特定していない。main Spotify は `CCCryptorCreateWithMode`／`CCCryptorUpdate` を import しているものの、再起動直後から計測した通常再生では両方 0 回だった。この import だけを根拠に AES 鍵をその境界で取得する設計は採らない。

旧 [YAD](https://github.com/p0rterB/YAD) の MIT ライセンス実装も切り分けた。C++ の鍵展開を iOS arm64 にビルドして同梱テストベクターが通ること、Apple CommonCrypto の AES-CTR が同ベクターの先頭 4,096 bytes と全バイト一致することを確認した。現行アプリの PlayPlay は **POST（body 30 bytes）**。同じアプリ内セッションで選んだ Vorbis file ID への GET は 400、アプリが使った POST body での呼び出しは 200／24 bytes だった。後者の 16 bytes と**同じ file ID** を YAD に渡して暗号化ファイル先頭を復号しても、想定位置 167 の `OggS` は出なかった。別の再起動 probe では、YAD が公開する旧 16-byte `playIntentToken` は現行 POST body のどの連続 16 bytes とも一致しなかった。旧来の音源ヘッダー／形式／オフセット仮定が外れた可能性もあり、これらの旧 probe だけでは鍵展開の差を切り分けられなかった。上記 v4 の同一要求・同一ID・同一応答16Bのプロセス内比較では、旧 YAD 出力と native record 先頭16Bが不一致だったため、**この build の fallback/format0 の1要求に限り**旧実装の互換性が否定された。全形式・全要求への一般化や不一致を生む具体的な演算段階は未確定で、`CCCryptorUpdate` の失敗ではない。鍵・Bearer・署名付き URL は evidence に記録していない。調査用 YAD dylib をアプリの書き込み可能 `Caches` からロードしようとすると iOS sandbox の executable `mmap` 制限で失敗したため、製品側に採用する場合は署名済み IPA／注入 dylib へ静的に組み込む必要がある。

同じアプリ内の Bearer で extended-metadata と storage-resolve を呼び、選択中の楽曲の暗号化 Vorbis 候補を CDN から **3,618,068 bytes** 取得した。HTTP 200 で `expectedContentLength` と保存サイズが一致。ファイル先頭もオフセット 167 も平文の `OggS` ではない。暗号化ファイルと file ID／形式の対応だけをアプリ sandbox の調査用 `Caches/EeveeOfflineProof` に置き、token／鍵／署名付き URL は保存していない。これを再生可能なダウンロードとは扱わない。現在の Spotify 本体は有用な PlayPlay／音声鍵／Vorbis シンボルを公開していない。再生前後に行った最大 256 MiB の読み取り可能領域の限定スキャンでも `OggS` は検出されなかったが、全メモリを調べた結果ではなく、平文 Ogg が存在しない証明ではない。

別に、Spotify の RemoteIO Audio Unit に `AudioUnitAddRenderNotify` を登録し、**Spotify が通常再生して PlayPlay 経路を通過した後の出力 PCM**を保存した。実機の input scope は 44.1 kHz、output scope は **48 kHz**、2 チャンネル非インターリーブ float32。output scope に合わせた事前確保メモリへ render callback 内で PCM16 をコピーし、callback を外してから WAV を書いた。出力スレッド上でファイル I/O は行わない。[Apple の render 通知仕様](https://developer.apple.com/documentation/audiotoolbox/audiounitaddrendernotify%28_%3A_%3A_%3A%29)

| 合格条件 | 実機結果 |
| --- | --- |
| 1 曲のフル尺 | 245.506 秒、11,784,288 フレーム、48 kHz stereo PCM16、WAV **47,137,196 bytes** |
| 取りこぼし／形式 | render 通知 11,637 回、採用区間に dropped 0／malformed 0。RIFF/data 長・形式・尺が一致 |
| 永続配置 | アプリ内から `Library/Application Support/EeveeOfflineProof/<UUID>/sample.wav` に移動。再起動後も同サイズで存在 |
| 通信遮断 | Wi-Fi を切り、SIM なし／モバイルデータ off の状態で `en0` の外部アドレス消失。外部 TCP は errno 51 |
| オフライン再生 | 保存 WAV をアプリ内 `AVAudioPlayer` で再生。約 3 秒後に再生位置 2.965 秒、240 秒へ seek 後約 2 秒で 241.964 秒。Spotify 再起動後も同様に再生・seek 成功 |
| 後片付け | render 通知を解除し、プレーヤー停止。Wi-Fi を元の SSID へ再接続し、外部アドレスを再取得 |

オフライン再生は端末内の WAV を Apple のファイルプレーヤーで行った。[`AVAudioPlayer` のローカルファイル再生 API](https://developer.apple.com/documentation/avfaudio/avaudioplayer/) これは **PlayPlay の鍵を独立に展開した証明、暗号化ファイルの直接復号、バックグラウンド高速ダウンロード、Spotify 純正キューやライブラリでの再生の証明ではない**。4 分の音源を約 4 分再生して捕捉する方式であり、純正 Premium download と同等の UX として採用する前に、PlayPlay の復号境界とローカル再生 resolver を別途確定する必要がある。調査用の Frida／SSH／icli／CModule は製品利用に含めない。使用した Core Audio／Foundation／AVFAudio API はアプリ内プロセスで動作したが、同じ実装の非脱獄注入 IPA での検証は行っていない。

### 未再生曲への PlayPlay 直接 POST one-shot の境界

2026-10-26、通常再生で得た native PlayPlay の 30-byte POST body とアプリ内 Bearer を、別曲の metadata から得る file ID に一回だけ用いる調査用 runner を用意した。結果は次のとおり。いずれも **直接 POST の RPC 呼び出しは 0 回**であり、未再生曲の鍵取得・復号・保存の成功例ではない。証拠は git 対象外の `Outputs/work/playplay-bulk-20261026/evidence/` にある sanitized JSON（各 `0600`）で、URI、file ID、Bearer、body、鍵、応答 bytes は記録していない。

| 証拠ファイル | 停止した段階と解釈 |
| --- | --- |
| `playplay-direct-post-1aa1fcabbad846208a357773657abaf0.json` | 最初の runner は native POST 件数がまだ正常な `0` の時点で `!= 1` を失敗としたホスト側の監視バグにより中止。再生ボタンは 1 回押したが直接 POST は呼んでいない。 |
| `playplay-direct-post-2cfba8f0999d4968952806ce88569e8f.json` | 修正後も通常再生の source 観測前に中止。旧証拠には例外型しかなく、native response timeout・件数異常などの個別原因を確定できない。 |
| `playplay-direct-post-0b81c64f904c4e638c54fea55dc5f6bc.json` | アルバム画面の `-URI`・タイトル・非再生ボタンを確認して 1 回押した後、再生中の表示は得たが `MPNowPlayingInfo` の current track URI は公式アルバム track URI 集合と一致せず、native PlayPlay POST は 0 件。`source_track_mismatch` で中止。別版への relink、Now Playing 値の形式・更新時点などは未切り分け。 |

各試行後、Spotify プロセスを先に終了して Frida script を解放し、X を前面に戻した。独立した後検査でも Spotify 不在、既存 index の SHA-256 と WAV 5 件の不変を確認した。次の設計検討では、公開ページの track URI 集合との一致は診断値に下げ、**native PlayPlay の単一 POST task とその応答の結合、source／target file ID の相違、target metadata の整合、鍵コピー slot の前後状態**を直接要求の本質ゲートとして再評価する。HTTP 200／24-byte 応答が得られても、それだけで 28-byte native record、暗号化音源の復号、オフライン再生を実証したことにはしない。

#### 受動 stage-count 診断（通常再生 1 回）

同日、直接 POST 用スクリプトを読み込まず、Spotify の通常再生ボタンを 1 回だけ押す受動 probe を追加した。固有の `0600` 証拠は [`playplay-stage-count-bdc559d3c2b64e5aad09fd6b71d82612.json`](../Outputs/work/playplay-bulk-20261026/evidence/playplay-stage-count-bdc559d3c2b64e5aad09fd6b71d82612.json)。証拠に URI、file ID、Bearer、HTTP body／応答 bytes、鍵、pointer は含めない。

画面の album `-URI`・タイトル・非再生ボタンは指定 source と一致し、tap 後は再生中表示だった。`SPTEsperantoPlayer` の state update から得た実際の track URI は Spotify track の正規形で、公式 album の 7 曲集合に一致した。一方、`MPNowPlayingInfo` の ExternalContentIdentifier は正規 track URI 形ではなく、その track と一致しなかった。したがって第 3 回 one-shot の `MPNowPlayingInfo` 集合不一致は、実再生曲が album 外だった証明ではない。匿名化した player-state track は tap 前後で同一で、tap は新曲の選択ではなく同じ曲の再開だった可能性が高い。

15 秒の観測窓では provider entry／return、非再生 prefetch entry、PlayPlay URLSession route／POST／task resume／応答の各件数がすべて **0**、Frida hook error は **0** だった。これは今回の source から新しい PlayPlay request が発生しなかった観測であり、既存鍵キャッシュ命中、別経路、hook 対象外のどれかを特定するものではない。直接 POST、未再生曲の鍵取得、保存・復号は実施していない。次の source 試験を設計する場合は、同じ曲の再開を避け、アルバム内の別曲セルを read-only で特定してからその曲を 1 回選ぶ必要がある。この最初の診断では別曲の選択操作は行っていない。

worker 内の後検査は Spotify 不在、X 前面、Spotify／Eevee binary hash・version/build、既存 index SHA／WAV 5 件の不変を確認した。ただし外側 watchdog は独立後検査のフィールド名不一致で例外終了し、その直後の別途 read-only 検査では X 前面・index 不変ながら Spotify の背景 process を検出した。worker 内の一時点の不在を最終端末状態と同一視しない。その後、親作業が背景 Spotify を 1 回終了し、X 前面・Spotify 不在・index SHA／WAV 5 件不変を独立に再確認した。watchdog のフィールド名はホストで修正・自試験し、追加の通常再生や HTTP 送信は行っていない。

#### 同アルバムの別曲を1回選ぶ受動診断

続いて read-only の UI tree で『Time Out』の曲行は共通 identifier `Components.UI.RetrievalRowElementUI` を持ち、個別の曲名・演奏者を含む label で識別できることを確認した。候補「Strange Meadow Lark」は画面内の完全一致 label が1件だけで、表示中・有効・操作可能な行だった。通常再生・保存を行わず画面を調べた後、Spotifyを終了して X 前面・Spotify 不在・index 不変へ戻した。[Spotify公式アルバムの曲一覧](https://open.spotify.com/embed/album/1L5YD0kUfBpmN4EOSoGo7m)

その後、[別曲1回タップの受動証拠](../Outputs/work/playplay-bulk-20261026/evidence/playplay-stage-count-alttrack-a0bd4d6bb8e9481c8747443fa3184a93.json)（`0600`）を取得した。実行前に Spotify 9.1.88 の executable SHA／LC_UUID／version/build、Eevee `-22` dylib SHA、X 前面・Spotify 不在・既存 index SHA／WAV 5 件、競合 probe 不在を検査した。曲行の完全一致・一意性と album ページ URI／タイトル、tap 前の player-state 曲が公式7曲集合内かつ候補曲とは異なることを確認して、候補行を **1回だけ** tap した。tap 後の匿名 player-state 曲は `T1` から別名へ変わり、公式7曲集合と候補曲の両方に一致した。URI や file ID の値は証拠に記録していない。

tap 直前から15秒後への受動カウンタ差分は、PlayPlay provider entry／return 各 **1**（非再生 prefetch callsite 1、再生 owner callsite 0）、async launch 1、handler の parsed／record／callback 到達点が各1。一方、監視した `NSURLSession`／`__NSURLSessionLocal` の PlayPlay route、POST、task作成・resume、応答はすべて **0** で、hook error・件数上限超過も0だった。これは別曲選択で provider と handler の一部が動いた一方、監視対象の HTTP 経路には要求が現れなかった観測である。キャッシュ命中、別 HTTP API、hook 対象外などを区別せず、handler到達だけで record の内容・鍵の有効性を認定しない。player-state URI は選択曲のモデル値であり、音声ストリームとの独立照合でもない。直接 POST、鍵・音源 bytes の取得、保存・復号は実施していない。

worker・外側 watchdog ともに正常終了し、終了時の独立検査でも X 前面、Spotify 不在、Spotify／Eevee binary hash と version/build、既存 index SHA／WAV 5 件は不変だった。背景 Spotify の再出現はなく、端末操作をここで終了した。

#### 自然 prefetch の対象曲・context・callback を同一要求で照合

上記とは別の正確な『Time Out』画面で「Three to Get Ready」の AX 曲行を一意に特定し、tap 前の player-state 曲がその候補とは異なることを確認してから **1 回だけ**選択した。公式アルバム上の次曲「Kathy's Waltz」について、アプリ内の既存 Bearer を使う extended-metadata **1 件**だけから format-0 の20-byte file IDを得た。HTTP 200、target URI・file ID の結合をプロセス内で確認し、storage-resolve/CDN は0件。曲 URI・file ID・Bearer・鍵の実値は証拠に出していない。[Spotify 公式 Time Out 曲一覧](https://open.spotify.com/embed/album/1L5YD0kUfBpmN4EOSoGo7m)

[受動照合証拠](../Outputs/work/playplay-bulk-20261026/evidence/prefetch-context-target-944f99277f9f42d585c889b52338a83b.json)（`0600`）では、tap 前に provider 呼出し0、tap 後に自然な prefetch callsite から2要求が発生した。両要求とも provider request・success/failure capture・prefetch object の20-byte IDが一致し、`x3` context presence byte は妥当な **0（contextなし）**。それぞれ成功 callback 1、28-byte record 非ゼロ、アプリ自身の stale-ID guard 通過、内部 key-cache insertion からの復帰1、failure／hook error／曖昧な callback 帰属0だった。対象「Kathy's Waltz」の metadata file ID はそのうち **slot 0 の要求 ID に一意に一致**した。これにより、この一回の通常操作で、未再生の次曲1件が contextなしの自然 prefetch で native record まで到達したことを確認した。監視した PlayPlay URLSession route／POST／task／応答は0で、今回は新規HTTP応答と record の因果関係を示さない。鍵の永続保持、アルバム全曲への拡張、独立要求、音源の新規保存／オフライン再生もこの probe からは導かない。

導入済み `7.0.0-22+debug` と SHA-256 が一致するローカル deb 内 `EeveeSpotify.dylib` を静的に照合すると、製品 `ppkc` には prefetch success 内の cache helper を対象にする hook 実装が含まれる。rootless 側は成功 callback の `Spotify+0x698C34C` から helper `+0x8532120` に入った場合、戻り先 `+0x698C350`・mode 2・非ゼロ ID／record を条件に、helper 復帰後に既存の file-ID 別鍵 slot へ値コピーする設計である。今回観測した native callback はその呼出し経路と条件に整合する。ただし、今回の probe は `ppkc_generation()` や対象 ID の製品 slot を測っていないため、`-22` で hook が実際に導入されたことや「Kathy's Waltz」の鍵が製品 slot に入ったことまでは実測済みとしない。非消費照会の `ppkc_has_for_file_id()` は現行作業ツリーにあるが、導入済み `-22` の Mach-O には含まれない。上記の provider **slot 0** は受動 probe の要求番号であり、製品 `ppkc` の鍵 slot 番号ではない。

最初の合成 probe は、stage 側 Interceptor の後に provider prologue の元命令を再読する順序で script error となり、曲 tap **0**・metadata **0** のまま停止した。元命令を overlay 前に固定照合し、後段は同一 image・期待命令の marker がある一箇所だけ再読を省くよう修正した。修正後の Node fixture／runner self-testと独立レビューを通して上記の一回を実施。両回とも Spotify を先に終了してから Frida を解放し、独立後検査で X 前面、Spotify 不在、Spotify／Eevee binary hash・version/build、索引 SHA-256 と WAV 5 件の不変を確認した。[初回停止証拠](../Outputs/work/playplay-bulk-20261026/evidence/prefetch-context-target-44214c7b51144ebcad04ced3a9f9f3a2.json)（`0600`）。

#### 別曲行からの PlayPlay 直接 POST one-shot 再試行

ヘッダーの再生ボタンでは現曲の再開になり得るため、[Spotify 公式『Time Out』](https://open.spotify.com/embed/album/1L5YD0kUfBpmN4EOSoGo7m)の7曲目「Pick up Sticks」の曲行を対象にした。事前の read-only AX 確認では、スクロール後の行は1件だけ表示・有効・操作可能で、中心点はヘッダーの再生ボタンと重ならなかった。runner は正確なアルバム画面と曲行を再確認し、tap 前の `SPTEsperantoPlayer` の正規 track URI が候補と異なること、source 捕捉が未開始で native 件数が0であることを確認してから捕捉を有効化し、その行を **1回だけ** tap した。tap 後の player-state は候補の正規 URI に一致し、tap 前から変化した。これは単なる現曲再開だった旧試験より強い曲選択の証拠だが、音声 bytes 自体の独立照合ではない。

[一回分の非公開証拠](../Outputs/work/playplay-bulk-20261026/evidence/playplay-direct-post-altrow-b9ee8e3f9f3d471282ce9aeeeb2e0044.json)（`0600`）では、その後25秒以内に監視対象の native PlayPlay POST task／同一 task の24-byte HTTP応答を観測できず、`native_response_timeout` で停止した。native source 捕捉 **0**、調査用 direct POST RPC **0**、直接送信 **0**、Frida hook error **0**。従って別曲の metadata 対象 ID への直接要求、鍵取得、保存、オフライン再生はこの回では行っていない。既存の鍵キャッシュ命中、別 HTTP 経路、hook 対象外などの区別も付かない。試験後は Spotify を停止してから script を解放し、外側 watchdog の独立後検査で X 前面、Spotify process 不在、既存索引 SHA-256／WAV 5 件の不変を確認した。製品コードと導入済み deb は変更していない。

この証拠の `selectedRowBound`／`preTapTrackDifferent`／`selectedTrackChanged`／`captureArmedBeforeTap` の偽値は、worker の真値を watchdog 側の初期偽値で上書きした**記録側の merge 不具合**により判定に使わない。tap 件数、候補 player-state 一致、native 件数、直接 RPC 件数、独立後検査はその不具合の対象外。merge 順序と host self-test は修正したが、上記の旧証拠を書き換えず、追加の実機再試行もしていない。調査 runner と自己テストは git 対象外の `Outputs/work/playplay-bulk-20261026/notes/` に保持する。

### Votify の AP 経路と iOS アプリ自身の経路を分離する

Votify の cookie／Android WVD／Windows DLL に依存しない候補は Vorbis と AP session の経路。Vorbis の audio-key は AP session を利用し、単なる `URLSession` の Bearer 付き通信や CommonCrypto の追加だけでは完結しない。[Votify の鍵取得分岐](https://github.com/glomatico/votify/blob/db14e4d1aa01456e0ec3b55d6f7268787ba2e2c4/votify/interface/audio.py#L293-L373)、[librespot の AP audio-key](https://github.com/librespot-org/librespot/blob/99b6088bf3ea028f90192676ac1a337fa4b2ed12/core/src/audio_key.rs#L81-L108)

今回の Votify 経路の照合では、Rust と Python librespot を区別した。Votify Python の入力は `AUTHENTICATION_SPOTIFY_TOKEN` と token の UTF-8 bytes。Python librespot 0.0.10 の metadata HTTP token は、APWelcome の reusable credentials から Login5 で別に作られる場合がある。Votify 全体の成功を、iOS の元 Bearer がすべての層でそのまま使える証拠にしない。[Votify の AP credential 構築](https://github.com/glomatico/votify/blob/db14e4d1aa01456e0ec3b55d6f7268787ba2e2c4/votify/api/librespot.py#L14-L31)、[Python HTTP request 認証](https://github.com/kokarare1212/librespot-python/blob/acd633d3eb26f7b61b21e5049cabb236b8f1298e/librespot/core.py#L107-L120)、[Login5](https://github.com/kokarare1212/librespot-python/blob/acd633d3eb26f7b61b21e5049cabb236b8f1298e/librespot/core.py#L2310-L2342)

iOS アプリの通常再生では、`playplay` と `storage-resolve` の HTTP 呼び出しを観測し、PlayPlay の応答形状までは確認した。これは Votify の AP audio-key 経路と別。次の焦点は 16 bytes の難読化キーから再生用鍵への iOS 側の展開境界と、保存した暗号化ファイルを直接復号・デコードする経路。現在の token で AP ログインを繰り返す調査は行わない。

Ogg/Vorbis の再生も別検証とする。実機 iOS 17.0 の Core Audio 読み取りファイル形式／decode format ID 列挙は成功したが、Ogg／Vorbis は一覧に含まれていなかった。Spotify 独自デコーダや Local Files scanner の対応は別問題であり、この列挙だけでは判定していない。対象 OS 全体で AVPlayer の直接再生を仮定せず、必要なら静的デコーダから PCM へ変換する。独立プレーヤーを加える場合は、Spotify のキュー、seek、Now Playing、音声割り込み、Connect との競合も実装範囲に含む。

調査用の [`stb_vorbis.c`](https://github.com/nothings/stb/blob/master/stb_vorbis.c) を使った Ogg→WAV 変換器は、公開サンプルと生成サンプルで RIFF サイズ・尺・破損入力を確認し、iOS 14 arm64 のオブジェクトまでコンパイルした。ただし実際の Spotify 暗号化音源には使用しておらず、製品の依存には追加していない。今回のフル尺 WAV は Spotify の再生出力から保存したものである。

## 初期調査時点の実装の検証順序（上記の製品経路検証より前）

1. PlayPlay 応答と 1 曲分の暗号化音源取得、実時間 PCM 保存／オフライン再生までは実証済み。次は iOS PlayPlay の鍵展開・復号境界を特定し、暗号化音源からの直接復号を検証する。token／鍵はメモリ内に限定し、端末外への出力を行わない。
2. 一時取得、キャンセル、容量不足、内容検証、atomic な最終配置、URI 索引を実装する。
3. ローカル再生を製品へ接続し、Wi-Fi／携帯通信のない状態、機内モード、アプリ再起動後の再生・seek を改めて確認する。今回の Frida probe での Wi-Fi 遮断と再起動テストは製品実装の代用にしない。
4. 実際の保存状態を、現行版の純正ダウンロード操作・ライブラリ・削除へ接続する。既存 UI が非表示のケースも扱う。
5. 同じ実装を署名済み IPA に注入する経路を用意する。非脱獄端末での動作試験は、後続のユーザー指定により今回の対象外。

この初期調査では、Swift の parser／hook 名を推測して UI だけ先に切り替える変更や、未検証の音源バックエンドの追加は行っていなかった。後続の実測に基づく実装と残課題は冒頭に記した。

## 再現用のメタデータ probe

`Scripts/probe-offline-download.js` の `rpc.exports.inventory()` は libobjc の runtime API だけを使用し、対象 class の名前、superclass、image path、own instance method の selector と type encoding を返す。引数、戻り値、リクエスト、楽曲、token、鍵は収集しない。アプリメソッドの呼び出しや `Interceptor` の登録も行わない。

単一の不正 UTF-8 や null metadata で調査全体を中断せず、skip 数を返す。走査中に class 数が増えた場合は確保済み配列の範囲だけを読み、`truncated` を明示する。継承メソッド、class methods、Swift vtable、protocol witnesses はこの probe の対象外。

実機の初回 RPC 実行では 102,494 class 中 314 class が対象となり、不正 UTF-8 の class 名 68 件を skip して完了した。runtime の class 数は画面や instrumentation の状態で変化する。

```sh
node --check /Users/yyyywaiwai/EeveeSpotifyReincarnated/Scripts/probe-offline-download.js
node /Users/yyyywaiwai/EeveeSpotifyReincarnated/Tests/OfflineDownloadProbe/test.js
```

Frida 接続先とプロセス名を `HOST`／`PORT`／`TARGET` に指定する。下記形式での CLI 実行も実機で確認した。これは調査用サーバーへの接続であり、製品機能の実行条件ではない。

```sh
frida -H HOST:PORT -n TARGET \
  -l /Users/yyyywaiwai/EeveeSpotifyReincarnated/Scripts/probe-offline-download.js \
  -q -e 'console.log(JSON.stringify(inventory(), null, 2))' -t 1 --exit-on-error
```

実機 evidence は `/Users/yyyywaiwai/EeveeSpotifyReincarnated/Outputs/work/votify-integration-20261026/evidence/` に保存した（git 対象外）。アプリの private container path や表示内容を含むため、そのまま公開しない。

追加調査の結果は同 evidence 配下の `media-session/` に保存した。HTTP／AP probe のソース、wire parser とその自己テスト、AP の署名・Shannon・フレーミング・HTTP 境界の自己テストも task の git 対象外領域に保存する。HTTP 200 と protobuf 内の status、暗号化データの取得、復号、オフライン再生は別の合格条件として扱う。

初期追加調査の evidence とコードは `Outputs/work/playplay-offline-20261026/` に保存した（git 対象外）。その時点の rootless build／実機試験で、PlayPlay 鍵レコードを使う直接復号・独立 WAV 保存、曲数1のアルバムの純正ボタンからの保存、Eevee のマイライブラリ行からの通信遮断後ローカル再生まで確認した。その後の多曲保存・IPA構造検証は本書冒頭に記録した。Spotify 純正保存モデルとの同等動作、任意未再生曲の鍵取得、非脱獄注入 IPA での実行時動作は未検証。上流 Votify はアカウント停止の報告を掲載しており、継続調査でも不要な認証再試行を避ける。[上流の注意事項](https://github.com/glomatico/votify/tree/db14e4d1aa01456e0ec3b55d6f7268787ba2e2c4#readme)

## 非脱獄注入 IPA の署名 readiness（2026-10-27、ホストのみ）

- 未署名 IPA の要求 entitlement は18キー。ローカルで有効なコード署名 identity は3件、復号できた provisioning profile は21件だが、元の Bundle ID と完全一致する profile は0件。開発 identity と一致し、元の Bundle ID を包含する有効な **iOS wildcard 開発 profile は1件**（登録端末9件）ある。別の wildcard profile 1件は非 iOS。対象 iPhone が登録端末に含まれるかは未確認。開発用 profile は登録端末向けであり、一般配布用の署名を証明しない。[Apple: 開発用 provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)
- この iOS profile が許可する entitlement は4キーだけで、元 IPA と共通の3キーも値はすべて不一致。残り15キーは、通知2、HealthKit 2、ローカルネットワーク2、Sign in with Apple・Associated Domains・CarPlay Audio・年齢範囲・Group Session・Siri・StoreKit 購入リンク・iCloud KVS・App Groups 各1。署名候補には元の値をコピーせず、選択した Bundle ID と profile に整合する application identifier／team identifier／keychain access group を生成し、profile 由来の debug 許可と合わせた最小4キーだけを使う必要がある。これら15 capability を外したときの Spotify 本体の機能・認証・起動は未検証。[Apple: App ID capability は allow list](https://developer.apple.com/help/account/identifiers/register-an-app-id)、[Apple: wildcard entitlement の展開と照合](https://developer.apple.com/library/archive/technotes/tn2415/)、[Apple: wildcard App ID の用途](https://developer.apple.com/library/archive/qa/qa1713/_index.html)
- 元の Bundle ID のまま別チームで署名すると既存アプリとの同居・更新で衝突し、application identifier 不一致による更新拒否があり得る。別 Bundle ID は衝突を避けられる一方、URL callback／Associated Domains、既存 keychain・共有領域へのアクセスが変わる。Eevee／PlayPlay 側の現行 hook は実行時の Bundle ID を条件にしないが、Spotify build/version、実行ファイル名・Mach-O UUID・命令フィンガープリントを照合するため、署名時にこれらを維持する。オフライン索引とファイルは app-local 保存で、sideload shim に keychain／App Group のフォールバックがあるが、Spotify 本体の認証・外部連携の同等動作までは保証しない。[Apple: Bundle ID はアプリを一意に識別](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)、[Apple: identifier 不一致による更新拒否](https://developer.apple.com/documentation/bundleresources/diagnosing-issues-with-entitlements)、[Apple: Bundle ID 変更時の関連設定](https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier)

署名済み IPA は作成していない。元の未署名 IPA はハッシュと権限が不変。次の署名ゲートは、使用する Bundle ID と必要 capability の決定、対応する iOS profile／証明書／対象端末登録の確認、署名後の embedded profile・bundle／entitlement 整合・`codesign --verify --deep --strict` の検証である。値非出力の監査結果は git 対象外の `Outputs/work/playplay-offline-20261026/nonjb-graft-research/full-ipa-9.1.88-20261026/evidence/ipa-signing-readiness-20261027.json`（0600）に置いた。実機での非脱獄動作試験はしていない。
