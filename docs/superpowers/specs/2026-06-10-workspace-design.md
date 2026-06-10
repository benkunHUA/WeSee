# Workspace Feature Design

## Overview

为智能体增加工作空间（workspace）定义功能，所有文件操作和 shell 脚本执行都在指定的工作空间目录下进行。采用 `WorkspaceManager` 共享状态方案。

## Architecture

```
client/WeSee/
├── Models/
│   └── WorkspaceManager.swift   # 新建：工作空间管理器
├── Services/
│   ├── AgentRunner.swift        # 修改：注入 WorkspaceManager 给 Tools
│   └── Tools/
│       ├── FileSystemTool.swift # 修改：动态读取 workspaceManager.currentURL
│       └── ShellTool.swift      # 修改：默认工作目录改为 workspace
├── Views/
│   └── Sidebar/
│       └── SidebarView.swift    # 修改：展示/修改工作空间
├── ViewModels/
│   └── ChatViewModel.swift      # 修改：传递 WorkspaceManager
└── ContentView.swift            # 修改：创建 WorkspaceManager 并注入
```

## Component Design

### WorkspaceManager

`@Observable` 类，全局共享实例。持有当前工作空间路径，负责持久化。

```swift
@Observable
final class WorkspaceManager {
    var currentURL: URL
    // load() → 从 config.json 读取 workspace 字段
    // save() → 写入 config.json
    // update(path:) → 修改、创建目录、持久化
}
```

- 默认值：`~/Documents/WeSee/`
- 配置键：`~/.config/wesee/config.json` 中新增 `workspace` 字段
- 加载时若 config 无 workspace 字段，使用默认值并自动写回
- `update` 时自动创建目录（`withIntermediateDirectories: true`）

### FileSystemTool 变更

- 原来 `rootDirectory` 在 init 时固定
- 改为持有 `WorkspaceManager` 引用
- `resolveSafePath` 改为动态读取 `workspaceManager.currentURL.path`

### ShellTool 变更

- 新增 `WorkspaceManager` 引用
- `runCommand` 中，若未指定 `working_directory`，默认使用 `workspaceManager.currentURL.path`
- 命令执行前验证 `working_directory` 在 workspace 范围内

### AgentRunner 变更

- init 接受 `WorkspaceManager`，在 `registerDefaultTools()` 中注入

### SidebarView 变更

- 底部增加工作空间显示：
  - 显示当前路径（只读文本）
  - 修改按钮 → `NSOpenPanel` 选择目录 → 调用 `workspaceManager.update()`

## Data Flow

```
WorkspaceManager (source of truth, @Observable)
  ├── SidebarView 读取 currentURL 展示
  ├── SidebarView 调用 update() 修改 → 自动持久化到 config.json
  ├── FileSystemTool.resolveSafePath() → 基于 workspaceManager.currentURL
  └── ShellTool.runCommand() → 默认 workingDirectory = workspaceManager.currentURL
```

## Error Handling

- workspace 目录创建失败：显示 errorMessage，回退到默认值
- config.json 读取失败：使用默认值，不阻塞
- NSOpenPanel 用户取消：无操作
- workspace 变更时当前有文件操作正在执行：tools 下次 execute 时自然生效

## Testing Strategy

- `WorkspaceManagerTests`：测试默认值、加载、保存、update 创建目录
- 现有 `FileSystemToolTests`、`ShellToolTests` 需适配新注入方式
