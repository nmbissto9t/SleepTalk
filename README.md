# 梦话记录

整夜监听麦克风，只保存检测到说话的片段。全部在手机本地运行，没有上传功能。

## 编译和安装

1. 在 GitHub 新建一个仓库，把本文件夹的全部内容上传到 `main` 分支（注意要包含 `.github` 文件夹）。
2. 上传后 GitHub Actions 会自动编译，约需几分钟。可在仓库的 Actions 页面查看进度。
3. 编译成功后，用 iPhone 的 Safari 打开仓库的 Releases → “最新版本”，下载 `SleepTalk.tipa`。
4. 在“文件”App 中分享这个文件，选择 TrollStore 安装。

如果编译失败，把 Actions 日志里的 `error:` 行发给 Claude 修改。

## 第一晚怎么测

1. 打开设置里的“保留所有片段（校准用）”。
2. 手机插电，放在枕边一两米内，点“开始监听”，然后锁屏。不要从后台划掉 App。
3. 早上点“结束监听”，看“实际监听”覆盖率、未监听时段和运行日志。

## 设置项

- 延迟开始：默认 15 分钟，可改为 0–240 分钟。期间麦克风开启但不保存声音。
- 放大回放音量：默认开启，只影响回放，不改变保存的文件。
- 自动清理鼾声：默认关闭，开启后删除超过保留天数且未收藏的鼾声。

## 调参

阈值集中在 `Sources/MonitorEngine.swift` 的 `Tuning` 里。灵敏度可以直接在 App 设置中调整。

## 代码结构

- `MonitorEngine.swift`：音频引擎、底噪跟踪、片段录制、声音分类、打断恢复、心跳
- `Storage.swift`：每晚一个文件夹，保存 `session.json` 和 `.m4a`
- `HomeView.swift` / `SessionDetailView.swift`：界面
- `Waveform.swift` / `ClipPlayer.swift`：波形和回放
- `.github/workflows/build.yml`：云端编译并打包成 `.tipa`
