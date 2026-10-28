# BoardCam (iPhone 盤面アプリ)

盤面を映しっぱなしにして、ダーツが刺さった位置(mm)だけを端末で取る。動画は残さない。

- キャリブレーション: 止めた1枚の上でブル中心 + ダブル外周(20/6/3/11 の真ん中)の5点をタップ。
  ダブル外径 393.7mm からホモグラフィを解く
- 着弾: 盤面が静止している前後の差分(src/board.py と同じ考え方)。チップは「盤面に近い端」
- 出力: 「ファイル」アプリ → BoardCam → sessions/<日時>/
  - `hits.csv` … src/board.py の hits.csv と同じ列 + `wall_time,r_mm,theta_deg,segment,img_before,img_after`
    (tip_*_px は 1920x1080 換算、frame は 30fps 換算、theta は +x=6 方向から反時計回り、90°=20)
  - `hitNNN_a.jpg / hitNNN_b.jpg` … 着弾前後の静止画(あとで Mac で再計算できるように)
  - `calib.jpg`, `calibration.json`
- 解析は [darts-home](https://github.com/sakiikapk/darts-home) 側。フォーム動画と合わせるときは今まで通り
  `python -m src.session <form_pose.csv> <sessions/.../hits.csv> --thrower ryo`

## ビルド(Mac)

Xcode 16 以上で `BoardCam.xcodeproj` を開く → Signing & Capabilities で Team に自分の Apple ID を選ぶ
→ iPhone をつないで ▶。無料の Apple ID だと7日ごとに入れ直し。

コマンドなら(チームIDはリポジトリに入れない):

```
xcodebuild -project BoardCam.xcodeproj -target BoardCam -sdk iphoneos -configuration Debug \
  DEVELOPMENT_TEAM=<自分のチームID> -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhoneのID> build/Debug-iphoneos/BoardCam.app
```
