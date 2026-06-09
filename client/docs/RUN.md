# WeSee 运行指南

## 前提条件

- macOS 14.0 或更高版本
- Xcode 16.0 或更高版本（App Store 免费下载）

## 运行步骤

### 1. 打开项目

在终端中进入项目目录，用 Xcode 打开：

```bash
cd /Users/haobenkun/Documents/workSpace/WeSee
open WeSee.xcodeproj
```

或者直接在 Finder 中双击 `WeSee.xcodeproj` 文件。

### 2. 选择运行目标

Xcode 打开后，顶部工具栏左侧会显示运行目标。确保选择 **"My Mac"**（本机）：

```
[ WeSee  v ] > [ My Mac ]
```

### 3. 运行

- 点击左上角 **▶️ 播放按钮**（或按快捷键 `Cmd + R`）
- Xcode 会自动编译并启动应用
- 首次编译可能需要 1-2 分钟，后续会更快

### 4. 应用窗口

启动后会出现 WeSee 窗口：

- **左侧栏**：功能菜单（新建会话、定时任务）+ 标签筛选
- **右侧**：聊天消息区 + 底部输入框

## 常用操作

| 操作 | 快捷键 | 说明 |
|------|--------|------|
| 运行 | `Cmd + R` | 编译并启动应用 |
| 停止 | `Cmd + .` | 停止运行中的应用 |
| 清理编译 | `Cmd + Shift + K` | 清理缓存，遇到奇怪问题时先用这个 |
| 运行测试 | `Cmd + U` | 执行单元测试和 UI 测试 |

## 命令行方式（可选）

不打开 Xcode 界面，直接在终端运行：

```bash
# 编译
xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug build -destination 'platform=macOS'

# 运行（编译产物在 DerivedData 中）
open ~/Library/Developer/Xcode/DerivedData/WeSee-*/Build/Products/Debug/WeSee.app

# 运行测试
xcodebuild -project WeSee.xcodeproj -scheme WeSee -configuration Debug test -destination 'platform=macOS'
```

## 常见问题

**应用启动后显示空白？**
正常现象。当前已实现完整 UI 框架，标签和消息需要运行时创建。输入消息即可开始使用。

**编译报错？**
先执行 `Cmd + Shift + K` 清理，再重新 `Cmd + R` 编译。

**提示开发者不受信任？**
系统设置 → 隐私与安全性 → 开发者工具 → 允许终端/Xcode。
