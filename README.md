# VideoCompare

macOS 本地视频对比 MVP。

## 运行

```bash
./scripts/build_app.sh
open dist/VideoCompare.app
```

此 MVP 使用 App 内的两个 `libmpv` 渲染实例进行硬解码播放。当前本机运行需要 Homebrew `mpv` 提供 `libmpv`：

```bash
brew install mpv
```

## MVP 功能

- 分别加载 A/B 两个视频，支持文件选择和 Finder 拖入。
- 支持 `mp4`、`mov`、`mkv`，播放能力由 `mpv`/FFmpeg/VideoToolbox 提供。
- 支持左右、上下、overlap 点击切换、overlap 拖动遮罩。
- 支持同步播放/暂停、单独播放/暂停、同步 seek、同步逐帧前进/后退。
- 支持 A/B 帧偏移，用于手动帧级对齐。
- overlap 模式下支持鼠标拖动平移当前选择的 A/B 视频，支持按钮缩放/重置；左右/上下布局不应用画面位置调整。
- 按住 Option/Alt 并上下拖动画面可连续缩放当前选中视频。
- 点击视频可选中 A/B；选中时左右方向键只调整该视频上一帧/下一帧并写入时间偏移，未选中时左右方向键同步逐帧。
- 空格键遵循同样逻辑：选中 A/B 时只切换该路播放/暂停，未选中时同步切换。
- 点击切换模式使用 Tab 键切换 A/B，不再用鼠标点击切换。
- 播放菜单提供“不加载字幕”，默认开启。
- 每个视频画面上方显示完整文件路径，避免遮挡视频内容。
- 按视频路径、文件大小、修改时间保存每组对齐参数，并支持清理当前组。
- 支持最近视频组。
