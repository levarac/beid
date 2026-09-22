# Delivery / CI contract (GitHub Actions + Xcode Cloud)

The platform delivery docs are `docs/xcode-cloud.md` for iOS and
`docs/google-play.md` for Android (canonical, each carries verification
dates). The contract every agent must know before touching delivery files:

## PR CI

- **この subsection が repository の PR CI lane 分担の正本。** 実行定義は
  `.github/workflows/pr-ci.yml` にある。現在の `pr-ci` はすべての PR と
  `main` への push で、Ubuntu 上に次の 3 job を実行する。
  - Android build: `:shared:testAndroidHostTest`、
    `:app:testDebugUnitTest`、`:app:assembleDebug`、
    `:app:compileDebugAndroidTestKotlin` (instrumented test source を
    **compile だけする** 別 step。emulator は使わず実行もしない。
    `androidTest` source set は `assembleDebug` でも `testDebugUnitTest` でも
    compile されないため、この step が無いと device-lab の instrumented test が
    engine API の変更で壊れても CI が緑のままになる)、`:app:dependencyInsight`
    (`org.levarac:barnard` の `debugRuntimeClasspath` resolution を build と
    test の step とは別の `./gradlew` 呼び出しとして追加実行し、その出力を
    `scripts/check_barnard_dependency_provenance.py` で検証する。resolved
    version が `android/app/build.gradle.kts` の宣言と一致すること、
    force override / project・composite-build substitution /
    `mavenLocal()` による差し替えが無いことを確認し、published dependency
    が実際に何へ resolve したかを CI log に machine-checkable な証拠として
    残す — gh#110)。あわせて build の前に `scripts/clone_parallax_pinned.sh` が
    `levarac/parallax` を **pin された commit で detached に clone** し
    (ref は `ParallaxEventDefinitionSourceChecksumTest` の
    `EXPECTED_PARALLAX_REF` から読む。YAML に write down しない)、
    `PARALLAX_REPO` を後続 step へ渡す。これにより vendored 資材のバイト比較が
    **毎回走る** — 従来は誰かが手元で環境変数を指したときにしか走らなかった
    (gh#415)。test の後に `scripts/check_parallax_comparison_ran.py` が
    JUnit XML を読み、比較の testcase が存在し skipped でないことを確認して
    job を落とす。**secret `PARALLAX_READ_TOKEN` が無い環境では clone せず、
    warning annotation と step summary を出して skip する** (緑と見分けが付く)。
    `PARALLAX_REPO` を空文字で export してはならない。設定済みだが存在しない
    path は misconfiguration として loud に落ちる仕様であり (gh#403 / PR #412)、
    未設定だけが skip してよい状態である
  - SwiftLint: `scripts/lint.sh`
  - repository sanity: XcodeGen YAML と TestFlight notes の JSON / 構造検証、
    `scripts/check_pr_ci_doc_drift.py` による本 subsection と workflow の
    drift 検査、`python3 -m unittest discover -s scripts/tests -t .` による
    `scripts/` の契約テスト (1 秒未満。gh#423 で追加するまで、この
    テスト群はどの workflow からも実行されていなかった)。**件数をここに書かない** —
    追加するたびに古くなり、しかもそれを検査するものが無い。drift 検出を説明する
    文書に、手で維持する数字を置かないこと

  - **`.github/workflows/pr-ci-lab-cli.yml`(beid#588、2026-09-17 追加)** —
    `tools/beid-lab-cli` (macOS の device-lab CLI) を
    `swift build -c release` + `swift test` で検査する lane。job 名は
    `beid-lab-cli build and test`。**required ではない**。同じ self-hosted
    Mac 上で動くが、**上の simulator lane とは別 workflow** である。理由は
    2 つあり、どちらも意図的:
    - この job は約 1 分で終わる。simulator lane の約 24 分に相乗りさせると、
      simulator test に影響し得ない変更のために #479 が意図的に狭めた
      trigger を広げることになる。**`pr-ci-ios-macos.yml` の `paths` に
      `tools/**` を足してはならない**
    - `synchronize` を**含む**。simulator lane が merge-candidate head を
      1 回測るのに対し、こちらは author が回しながら見る fast feedback で
      あり、`opened` だけでは 2 commit 目以降すべて stale になる。
      同じ理由で draft guard も無い (1 分は draft から取り上げる価値が無く、
      draft こそこの答えが欲しい時である)
    job 内の step は `scripts/ci_change_filter.py` の `labcli` 出力で gate
    される。`paths` が workflow を起動するかを決め、classifier が build する
    価値があるかを決める — つまり `tools/beid-lab-cli` の「この変更は build が
    要るか」の定義が YAML の glob と Python の規則に分裂せず 1 つで済む。
    classification が壊れたら全 lane true に倒れる (fail closed) ので、
    gate の故障は skip ではなく build になる。
    **`tools/beid-lab-cli/` は Android lane と SwiftLint lane を起動しない** —
    どの app target も link していない standalone SwiftPM package なので。
    ただし `Package.resolved` の basename 規則からの除外は
    `tools/beid-lab-cli/` だけに効く。`tools/` 配下の未分類の path は従来どおり
    fail closed のままである。

  - **Xcode Cloud requirement classification** — the same
    `scripts/ci_change_filter.py` result exposed by the `changes` job has an
    `xcode_cloud` output. Pure Android app source/resources/tests under
    `android/app/src/` set it to `false`; Android build inputs, shared code,
    iOS/native Swift, workflow/scripts, and unknown paths set it to `true`.
    This is a merge-evidence requirement decision, separate from whether App
    Store Connect starts a workflow. Do not exclude all of `android/`.

  **2026-09-02 以降、native iOS の build / test は 2 系統ある。** どちらも
  この subsection が正本で、他の文書は分担を複製せずここと実行定義を参照する。

  - **Xcode Cloud** — merge 判断の対象 when `xcode_cloud=true`.
    **branch protection による強制ではない。**
    この repository に branch protection は存在しない (`GET
    /repos/.../branches/main/protection` は 403 *Upgrade to GitHub Pro or make
    this repository public* を返す)。つまり required context は 1 つも設定されて
    おらず、**「すべての required check が緑」と「required check が 1 つも無い」
    は GitHub 上で区別が付かない** — `mergeStateStatus` の `CLEAN` はどちらでも
    同じように出る。したがって iOS check を待つのは**運用ルールとしての hard
    stop** であって仕組みではない。人が守らなければ何も止めない。
    稼働状況をここに書かない — compute 枠は動くので、状態を書き写した瞬間に
    古くなる (#433 が同じ subsection に入れた「件数をここに書かない」と同じ
    失敗を、件数ではなく**状態**という通貨でやることになる)。現在動いているか
    は **ASC の GUI が正本** (本ファイルが workflow 設定について既にそう宣言して
    いる) で、判断対象の head に check が存在し succeeded かどうかは
    `gh pr checks` が答える。
  - **`.github/workflows/pr-ci-ios-macos.yml`(#301、2026-09-02 追加)** —
    self-hosted runner `emi` 上の **informational-only** lane。job 名は
    `iOS simulator (self-hosted macOS, informational)`。**required ではない**。
    **起動条件は次の 3 つだけであり、PR への push 毎ではない**
    (#479、2026-09-10 に変更): (1) `pull_request` の `opened` と
    `ready_for_review`、(2) `push` の `main`、(3) `workflow_dispatch`。
    (1)(2) には従来どおり `paths` filter がかかり、`ios/` `shared/`
    Android build 関連パスの変更でのみ起動する。`workflow_dispatch` に
    `paths` は効かないので、手動実行は常に走る。`synchronize` を外した理由は、
    この lane が 1 回あたり約 30 分かかりながら merge を gate せず、同じ head を
    Xcode Cloud の `Beid | PR Build & Test | Test - iOS` が約 12 分で検証して
    いるため。**コストの実体は TestFlight 配信の遅延であって、開発機の取り合い
    ではない。** この repository の self-hosted runner は `emi` ただ 1 つで、
    `internal-testflight.yml` と `release-testflight.yml` はどちらも
    `runs-on: [self-hosted, emi]`、つまり同じ 1 つの runner を要求する。
    配信側の concurrency group (`beid-ios-delivery`) はこの lane のものとは
    別なので、両者を直列化しているのは GitHub の concurrency ではなく
    **runner が 1 つしかないこと**である。したがって誰も merge しない中間 head
    への 30 分の informational run が、**テスターが待っている TestFlight
    ビルドの前に居座り得る**。2026-09-10 の実測では 10 run が 1 日にその runner
    を 274 分占有し、うち 147 分は 1 本の PR の 6 push 分だった。
    **訂正 (2026-09-10)**: この節は当初「同じ host をローカルの iOS フルスイート
    と共有しており人手の検証が待たされる」と書いていた。**それは誤り。** `emi` は
    別のホストで、それらのローカル実行が動く開発機には runner が 1 つも登録されて
    いない (実測 0 プロセス)。よって当該 run がローカルの Gradle や simulator に
    触れたことは一度も無い。絞る判断自体と実測値は変わらず、**害の同定だけが
    間違っていた**。削除ではなく訂正として残すのは、旧記述が #479 とレビューで
    引かれたため。
    **`opened` を入れてあるのは、`ready_for_review` が draft から上げた時に
    しか発火しないため。** issue #479 の本文は `ready_for_review` 単独を
    指定していたが、直近 25 本を timeline で数えると決着済み 22 本のうち
    13 本が `ReadyForReviewEvent` を持たず (ios 直撃のものを含む)、それだと
    PR の約 4 割しかカバーしない。非 draft で open された PR は open した
    瞬間から merge 候補の head を持つので、`opened` を足す方が issue の
    意図に沿う。**受け入れ基準 4 つは狭い方の集合でも満たせてしまうので、
    基準の充足を正しさの証明として扱わないこと。**
    **`opened` は draft PR でも発火するため、draft の除外は job 側の
    `if` が担う** (`github.event_name != 'pull_request' ||
    github.event.pull_request.draft == false`)。`paths` と `types` だけでは
    「draft でない」を表現できない。`event_name` の節は必須で、これを外すと
    `push` と `workflow_dispatch` では `github.event.pull_request` が存在せず
    式全体が false になり、main の計測が止まる。
    **PR で走ったことは、merge される head で走ったことを意味しない。**
    `synchronize` が trigger でない以上、非 draft の PR はこの lane を
    「open した時の head で 1 回」だけ走らせ、その後の push は head を
    変えたまま再実行しない (un-draft 後も同じ)。したがって
    **「PR でこの lane が緑だった」から merge 対象 commit の iOS 検証を
    導いてはならない**。merged 版を担保するのは `main` への push の方で、
    それは merge の後に走る。
    **観測上の注意**: draft PR を open した時は run 自体は記録され、job が
    `skipped` になる。draft PR への push は `synchronize` が trigger でない
    ため run 自体が記録されない。「起動しない」の証拠はこの 2 つで形が違う。
    **`skipped` の job が runner を占有する時間はゼロ秒**である (PR #486、
    2026-09-10 に初観測。job が `steps=0` で `started_at` と `completed_at` が
    同一)。上のコストモデルからすると、draft gate の価値はここにある —
    draft PR は runner を一切占有しないので、TestFlight ビルドを遅らせ得ない。
    **`concurrency` は `github.ref` 単位で `cancel-in-progress: true` のまま**
    なので、main への連続 merge では前の main run が cancel される。merge 毎に
    run が「起動する」ことは保証されるが、**完走は保証されない**。
    起動条件そのものは `scripts/tests` 配下の contract test が固定しており、
    Repository sanity job の `python3 -m unittest discover -s scripts/tests -t .`
    で毎 PR 実行される (この subsection が件数もファイル名も書かないのは
    上と同じ理由 — 追加のたびに古くなるため)。
    Debug simulator build/test の集計後、テスト結果にかかわらず Release device
    build (`CODE_SIGNING_ALLOWED=NO`) も実行し、Release-only の compile regression
    を検出する。個々の step を `continue-on-error` にはせず、lane 全体が
    informational-only である既存の境界を保つ。
    Xcode Cloud への依存を段階的に減らすための実績積みの段階であり、
    Xcode Cloud の設定・branch protection・他の workflow は変更していない。

  **`scripts/check_pr_ci_doc_drift.py` はこの 2 本目を検査していない。**
  同スクリプトは `.github/workflows/pr-ci.yml` のみを対象としており、
  **iOS lane が変わってもこの記述は緑のまま古くなる**。lane を触る変更は、
  検査に頼らずこの subsection を手で更新すること。#479 で
  `scripts/tests` に追加した contract test が固定するのは iOS lane の
  **起動条件だけ**であって、この subsection の散文ではない。起動条件以外は
  依然として手で追随させる必要がある。
- GitHub branch protection は approving review を merge 条件にしない。
  これは 2026-07-27 のオーナー判断による repository setting であり、
  上の KMP review gate を免除しない。KMP の independent review は作業上の
  gate、GitHub の approving review は merge button の設定で、別の条件である。

### iOS delivery fallback lane (GitHub Actions)

- **2026-09-08 現在、iOS の TestFlight delivery は Xcode Cloud が担う。** budget が
  戻ったので PR の Build & Test workflow を再度有効化し、delivery は Xcode Cloud の
  Internal Build / Release Build に戻した。GitHub Actions lane は fallback として
  残してあるが動いていない — repository variable `GHA_DELIVERY` は `off`。再び
  Xcode Cloud が使えなくなったら `GHA_DELIVERY` を `on` にすれば GitHub Actions lane
  が delivery を代行する。Xcode Cloud の workflow 設定はどちらの向きでも削除・変更
  しない。
- `.github/workflows/internal-testflight.yml` は `main` への push のうち
  `what_to_test.json` または `what_to_test.ios.json` が変わった時と、手動実行で
  起動する。`.github/workflows/release-testflight.yml` は `release/**` branch
  への push と手動実行で起動する。両方とも `GHA_DELIVERY == on` の時だけ
  self-hosted runner `emi` 上で動き、同じ concurrency group で直列化する。
- 共通処理は `scripts/gha/build-and-upload-ios.sh` に置く。XcodeGen の pin と
  drift guard は Xcode Cloud の `ci_post_clone.sh` と同じ契約を守り、Release
  archive をtemporary lane内だけManual / Apple Distributionで署名して生成し、
  `xcodebuild -exportArchive` で App Store Connect へuploadする。通常のproject
  signing設定とXcode Cloudは変更しない。build number は
  `manageAppVersionAndBuildNumber` でAppleに採番させる。
- ASC API key と team ID は repository secret ではなく、runner-local の
  `$ASC_CRED_DIR/env` とそこから指す key file から実行時に読む。値を workflow
  や log に出してはならない。
- Apple Distribution identity はrunner-localの専用keychain
  `~/Library/Keychains/beid-ci.keychain-db`に置く。job開始時にrunner `.env`の
  `BEID_CI_KEYCHAIN_PASSWORD`でunlockし、設定済みteam IDに一致する有効identityを
  確認してからarchiveする。passwordをrepository・GitHub Secrets・logへ出さない。
- App Store provisioning profile `Beid GitHub Actions App Store` はrunner-localに
  installする。`project.yml`はBeid targetのReleaseだけで
  `PROVISIONING_PROFILE_SPECIFIER=$(BEID_PROVISIONING_PROFILE)`を参照し、GitHub
  Actionsのarchive時だけ同変数へprofile名を渡す。未設定のXcode Cloudでは空に
  解決されるため、通常のAutomatic signingを変えない。
- GitHub Actionsのexportもmanual signingとし、ExportOptionsの
  `provisioningProfiles`で`org.levarac.beid`を同profileへ対応づける。これにより
  ASC cloud signing permissionに依存せず、runner-localのidentity/profileを使う。
- GitHub Actions upload は **upload 後に What to Test を書き込む** (#503、
  2026-09-11)。`scripts/gha/set_testflight_whats_new.py` が
  `what_to_test.ios.json`(無ければ `what_to_test.json`)の文面を App Store
  Connect API の `betaBuildLocalizations` の `whatsNew` へ入れる。Xcode Cloud は
  `ios/TestFlight/WhatToTest.<locale>.txt` を自分で拾うのでこの経路は要らないが、
  `xcodebuild -exportArchive` にその慣習は無く、API 以外の手段が無い。
  **runner に新しい依存は入れていない** — ES256 JWT の署名は macOS 同梱の
  `openssl` に投げ、残りは python3 標準ライブラリだけで書いてある。build 番号は
  Apple が export 時に採番するので export 成果物から読み、読めなければ
  **落ちる**。「一番新しい build」への fallback は意図的に持たせていない
  (他人の build に文面を書き込むのは書かないことより悪い)。notes 書き込みの失敗は
  job を落とす — テスターに文面が届かない緑の配信は、この lane が防ぐべき
  silent failure そのものだから。⚠️ **この経路はまだ実配信で観測していない。**
  `GHA_DELIVERY` は現在 off で、テスターに文面が見えることの確認は
  dispatch#29 のゲートに置かれている。

### Temporary Android delivery lane (GitHub Actions)

- `.github/workflows/internal-google-play.yml` は `main` への push のうち
  `what_to_test.json` または `what_to_test.android.json` が変わった時と、
  手動実行で起動する。**`GHA_ANDROID_DELIVERY == on` の時だけ** self-hosted
  runner `emi` 上でAABをbuild・署名し、Google Play internal testingへupload
  する。
- **Android lane の gate は iOS lane と別の変数である** (#401 で分離、
  2026-09-10)。分離前は両方とも `GHA_DELIVERY` だった。`GHA_DELIVERY` は
  `internal-testflight.yml` と `release-testflight.yml` も gate しており、
  かつ `internal-testflight.yml` は `what_to_test.json` の `main` への push で
  発火する — **この Android workflow を発火させるのと同じ file** である。
  したがって変数が 1 つだと、Android の配信を有効にする操作と、同じ commit から
  App Store Connect へ iOS を upload する操作が**区別できなかった**。
  「Android だけ」を表現可能にするための分離であって、設定の整理ではない。
  `GHA_ANDROID_DELIVERY` は iOS lane に影響せず、`GHA_DELIVERY` は Android lane
  に影響しない。無効化も別々に行う。
  **Xcode Cloudの稼働状況をここに書かない** — 上の PR CI subsection と同じ理由で、
  書き写した状態は次に枠が動いた瞬間に古くなる。現在の値は repository variable が
  正本。Android側にXcode Cloudの代替元はないため、恒久運用は別途決める。
- runnerは`ANDROID_HOME`と`KMP_JAVA_HOME`を持ち、Gradleは必ずrepositoryの
  `scripts/resolve_kmp_java_home.sh`が選ぶJDK 17で動かす。ambientなsystem Javaを
  使ってはならない。
- Play service-account JSONとupload keystoreはGitHub Secretsへ移さず、
  runner-localの`$PLAY_CRED_DIR/env`とそこから指すfileから読む。passwordは
  logやprocess command lineへ直接展開しない。
- repositoryの`android/app/build.gradle.kts`にはrelease signing設定を追加しない。
  workflowはunsigned AABを生成後、runner-local upload keyで`jarsigner`署名する。
  temporary laneのversionCodeはworkflow runから10億台で採番し、sourceの
  `versionCode=1`を変更しない。
- Google Playのapp record、初回manual AAB upload、upload key登録、service
  account権限付与が完了するまではactivation blockedである。正確なrunner設定と
  Ken側activation手順は`docs/google-play.md`を参照する。

- **"Ship a TestFlight test build" = update `what_to_test.json`** (repo
  root). Both delivery paths now trigger from this change on `main` **and**
  publish its text as the tester-facing "What to Test" notes — Xcode Cloud
  through `ios/TestFlight/WhatToTest.<locale>.txt`, the temporary GitHub
  Actions lane through the App Store Connect API after its upload (#503).
  The Android lane publishes the same text as Google Play release notes.
  Neither publication has yet been observed by a tester; that observation is
  dispatch#29's gate. Rewrite
  the file wholesale each time — what to check in *this* build
  only, 1-3 plain sentences (ASC locale: `en-US` only), no PR
  numbers, no internal jargon, no accumulated history.
- **`release_notes.json` is App Store "What's New" copy.** On non-release
  branches it is never delivered to testers and editing it neither
  triggers nor annotates test builds. Caveat: on `release/*` branches the
  current `ci_post_xcodebuild.sh` sources TestFlight notes from
  `release_notes.json` instead (a legacy pattern slated for revision in
  issue #55 — the sister project that originated it abandoned it after
  shipping stale tester notes for 19 hours through exactly this file
  confusion). When in doubt, the file you want is `what_to_test.json`.
- **Versioning**: `MARKETING_VERSION` lives once in `ios/project.yml`
  (the project is xcodegen-generated — never hand-edit the `.xcodeproj`).
  Xcode Cloud builds use the Xcode Cloud run number. The temporary GitHub
  Actions lane asks Apple to assign the next build number during export.
  `CURRENT_PROJECT_VERSION` in `project.yml` remains an inert placeholder
  (`"1"`) in both paths — leave it, never bump it per build.
- **"Uploaded" ≠ "delivered"**: a build can be `VALID` in App Store
  Connect yet reach no tester. Internal builds auto-deliver to the "Dev"
  TestFlight group via the ASC workflow post-action (configured
  2026-07-23; permanence re-confirmed per issue #37); verify group
  assignment through `GET /v1/betaGroups/{id}/builds` (the reverse
  direction reads empty for internal groups).
- **ASC GUI is the source of truth for workflow settings** — they are not
  in this repo and can drift from the docs. When observed behavior
  contradicts `docs/xcode-cloud.md`, trust App Store Connect, then update
  the doc with a new verification date.
- Release-branch conventions (`release/X.Y.Z` stabilization branches,
  version rules, CI guards) are being established in issue #55 — read it
  before doing release work.
- **Code signing / team ID**: `DEVELOPMENT_TEAM` in `ios/project.yml` is
  the maintainer's personal Apple Developer team. To build on a device
  with a different account, change the team locally (Xcode signing pane
  or a local `project.yml` edit + `xcodegen generate`) — but **never
  commit a team-ID change**. PRs that touch `DEVELOPMENT_TEAM`, bundle
  identifiers, or signing settings are rejected unless the maintainer
  authored them.
