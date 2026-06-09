# WeSee 桌面端聊天工具设计

**日期**: 2026-06-09
**状态**: 设计方案

## 概述

WeSee 桌面端（macOS）聊天工具，伴侣间查看工作与生活状态。左右两栏布局：左侧菜单栏 + 右侧聊天区。

## 架构选择

**MVVM + SwiftData** — Apple 原生技术栈，SwiftData 持久化，`@Observable` 宏响应式绑定，预留 `RemoteClient` 协议便于后续接入远端服务。

## UI 布局

```
+------------------+---------------------------+
|   左侧菜单栏      |      右侧聊天区             |
|                  |                           |
|  [新建会话]       |   消息列表                 |
|  [定时任务]       |   ┌─────────────────┐     |
|                  |   │ 消息泡泡 (对方)   │     |
|  标签/筛选列表     |   │      消息泡泡 (我) │     |
|  ┌──────────┐    |   │ 消息泡泡 (对方)   │     |
|  │ 工作 (3)  │    |   └─────────────────┘     |
|  │ 生活 (5)  │    |                           |
|  │ 计划 (2)  │    |   [输入框........] [发送]  |
|  │ 全部     │    |                           |
|  └──────────┘    |                           |
+------------------+---------------------------+
```

## 数据模型

### Message（核心）
| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID | 主键 |
| content | String | 消息内容，最大 5000 字符 |
| timestamp | Date | 发送时间 |
| isFromMe | Bool | 是否本人发送 |
| tags | [Tag] | 多对多关联 |
| isBookmarked | Bool | 是否书签标记 |

### Tag
| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID | 主键 |
| name | String | 标签名 |
| color | String | 标签颜色 hex |
| messages | [Message] | 反向关联 |

### ScheduledTask
| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID | 主键 |
| type | TaskType | .sendMessage / .syncStatus / .reminder |
| title | String | 任务名称 |
| cronExpression | String | cron 表达式 |
| isEnabled | Bool | 是否启用 |
| nextFireDate | Date? | 下次触发时间 |

## 视图层级

```
WeSeeApp
└── ContentView (NavigationSplitView)
    ├── SidebarView
    │   ├── FunctionMenuView
    │   │   ├── 新建会话
    │   │   └── 定时任务
    │   └── TagFilterListView
    │       └── TagRow (每行一个标签 + 消息计数)
    └── ChatView
        ├── MessageListView
        │   └── MessageBubble
        ├── MessageInputBar (输入框 + 发送按钮)
        └── ScheduledTaskSheet (弹出层)
```

## 文件结构

```
WeSee/
├── App/WeSeeApp.swift
├── Models/
│   ├── Message.swift
│   ├── Tag.swift
│   └── ScheduledTask.swift
├── Views/
│   ├── ContentView.swift
│   ├── Sidebar/
│   │   ├── SidebarView.swift
│   │   ├── FunctionMenuView.swift
│   │   └── TagFilterListView.swift
│   └── Chat/
│       ├── ChatView.swift
│       ├── MessageBubble.swift
│       ├── MessageListView.swift
│       └── MessageInputBar.swift
├── ViewModels/
│   ├── ChatViewModel.swift
│   └── SidebarViewModel.swift
└── Services/
    └── RemoteClient.swift (预留协议)
```

## 数据流

1. **发送消息**: 用户输入 → sendButton → ChatViewModel.addMessage() → SwiftData 写入 → @Query 自动刷新 MessageListView
2. **标签筛选**: 点击 TagRow → SidebarViewModel.selectedTag → ChatViewModel.filteredMessages → MessageListView 更新
3. **定时任务**: Timer 触发 → ScheduledTask 执行 → 发消息/提醒/同步

## 边界情况

| 场景 | 处理 |
|------|------|
| 空消息 | 发送按钮 disabled |
| 超长消息 | 限制 5000 字符，超出截断并 toast |
| 无标签 | 显示"全部"，空列表显示引导文字 |
| 存储异常 | toast 提示，消息不丢失 |
| 快速连续发送 | 发送后清空输入框，0.3s 内禁用 |
| 空历史会话 | 显示引导页 "开始你的第一条消息" |

## 测试策略（目标覆盖率 ≥ 80%）

### 单元测试
- ChatViewModel 消息增删查逻辑
- Tag 筛选过滤算法
- ScheduledTask cron 表达式解析
- 消息长度校验

### 集成测试
- SwiftData ModelContainer 读写
- ViewModel ↔ Model 联动

### UI 测试
- 侧边栏点击 → 视图切换
- 消息发送完整流程
- 标签筛选后消息列表变化
