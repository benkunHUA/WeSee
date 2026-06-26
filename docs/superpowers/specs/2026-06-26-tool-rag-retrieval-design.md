# 工具 RAG 检索优化设计

日期：2026-06-26

## 目标

将工具（tools）的描述信息向量化存储到 Milvus，每次用户查询时通过 RAG 检索最相关的工具，仅将匹配的工具传入大模型上下文窗口。避免工具数量增长后全量加载占用过多 token。

## 范围

本阶段包含：

- 启动时扫描所有已注册工具的 name + description，通过 DoubaoEmbedder 做 embedding 写入 Milvus Lite。
- 每次用户查询时，对用户输入做 embedding 检索 Top-K 个最相关工具。
- 支持"常驻工具白名单"：指定基础工具始终加载，其余工具按需检索。
- RAG 任何环节失败时降级为全量加载，保证 agent 仍可运行。
- 新增 `ToolIndex` 组件封装 Milvus 读写，AgentRunner 增加可选 `tool_index` 参数。

本阶段不包含：

- 工具描述热更新（需重启生效）。
- 工具元信息外部化（仍保留 Python 类定义）。
- 多用户/多租户隔离。

## 设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| 工具定义方式 | Python 类（方案 A） | 改动最小，当前工具数量少 |
| 重复数据处理 | name 主键 upsert | 每次重启覆盖旧记录，不产生重复 |
| 基础工具策略 | 白名单始终加载 | shell + file_system 几乎每次对话都用 |
| 检索策略 | 固定 Top-K | 简单可靠，不加阈值过滤 |

## 数据模型

### Milvus Collection：`tool_index`

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | VARCHAR(64) | 主键，工具 name（如 `shell`、`file_system`、`screenshot`） |
| `description` | VARCHAR(512) | 工具的 description 原文，供调试查看 |
| `vector` | FLOAT[1024] | description 的 embedding 向量 |

- embedding 维度 1024，来自 `doubao-embedding-vision` 模型输出。
- `id` 作为主键，同一 name 重复 upsert 会覆盖旧记录，不会产生重复数据。

## 运行时架构

### 新增组件：`ToolIndex`

位置：`server/tools/index.py`

接口：

```python
class ToolIndex:
    def __init__(self, embedder: Embedder, milvus_path: str): ...

    async def build_index(self, tools: list[BaseTool]) -> None:
        """启动时调用：创建 collection（如果不存在），upsert 所有工具"""

    async def search(self, query: str, k: int = 2) -> list[BaseTool]:
        """对用户输入做 embedding，返回 Top-K 相似工具（不含已去重的白名单）"""
```

### 修改组件：`AgentRunner`

位置：`server/agent/runner.py`

新增可选参数 `tool_index` 和 `whitelist`：

```python
class AgentRunner:
    def __init__(
        self,
        config: ServerConfig,
        tools: list[BaseTool],
        *,
        tool_index: ToolIndex | None = None,
        whitelist: set[str] | None = None,
    ): ...
```

`tool_index` 为 `None` 时跳过检索（兼容现有测试和降级场景），直接将 `tools` 全量传给 agent。

### 工具解析逻辑

```python
async def _resolve_tools(self, user_query: str) -> list[BaseTool]:
    if self.tool_index is None:
        return self.all_tools
    try:
        rag_tools = await self.tool_index.search(user_query, k=2)
    except Exception:
        # 降级：检索失败时全量加载
        return self.all_tools
    selected = set(self.whitelist or set()) | {t.name for t in rag_tools}
    return [t for t in self.all_tools if t.name in selected]
```

### 启动流程

```
main.py
  → 创建 ShellTool、FileSystemTool、ScreenshotTool 实例
  → all_tools = [shell, file_system, screenshot]
  → ToolIndex(embedder, milvus_path)
  → ToolIndex.build_index(all_tools)   // 首次创建 collection + upsert
  → whitelist = {"shell", "file_system"}
  → AgentRunner(config, all_tools, tool_index=index, whitelist=whitelist)
```

## 数据流

### 查询时工具选择

```
用户消息 "截图保存到桌面"
       │
       ▼
  AgentRunner._resolve_tools("截图保存到桌面")
       │
       ├─ whitelist = {shell, file_system}
       │
       └─ ToolIndex.search("截图保存到桌面", k=2)
              │
              ▼
           DoubaoEmbedder.embed(["截图保存到桌面"])
              │
              ▼
           Milvus.search(vector, top_k=2)
              │
              ▼
           返回 [screenshot, shell]（按相似度排序）
              │
              ▼
           selected = {shell, file_system} ∪ {screenshot, shell}
                    = {shell, file_system, screenshot}
              │
              ▼
           final_tools = [shell, file_system, screenshot]
```

### 白名单 vs RAG 结果合并

- 白名单硬编码在 `main.py` 中，当前为 `{"shell", "file_system"}`。
- 后续可通过环境变量 `WESEE_TOOL_WHITELIST` 或配置文件扩展。
- 白名单 + RAG 结果取并集去重，白名单中的工具不会被 RAG 遗漏影响。
- 当工具总数 ≤ 白名单数量时，跳过 RAG 检索。

## 错误处理与降级

| 场景 | 行为 |
|------|------|
| Milvus 文件不存在（首次启动） | `build_index` 自动创建 collection |
| Embedding API 不可用（`build_index` 阶段） | 记录警告，跳过索引构建；后续查询降级为全量加载 |
| Embedding API 不可用（`search` 阶段） | 降级为全量加载，返回全部工具 |
| Milvus 搜索失败 | 捕获异常，降级为全量加载 |
| 工具数量 ≤ 白名单数量 | 跳过 RAG 检索，直接返回白名单工具 |

核心原则：**RAG 是优化手段，不是硬依赖。任何环节失败都降级到全量加载，保证 agent 功能不受影响。**

## 测试策略

1. **ToolIndex 单元测试**  
   使用 Milvus Lite 临时目录，mock embedder 返回固定向量，验证 build + search 的往返正确性，以及 upsert 不会产生重复记录。

2. **_resolve_tools 测试**  
   `tool_index=None` 时返回全量工具；`tool_index` 提供 mock 检索结果时正确合并白名单；检索抛异常时降级为全量。

3. **现有测试回归**  
   `AgentRunner` 的 `tool_index` 默认为 `None`，行为与当前完全一致。现有 90 个测试不受影响。

4. **降级端到端验证**  
   模拟 embedding API 不可用（无效 ark_api_key），确认 agent 仍能启动和响应。

## 后续扩展

- 工具描述热更新（不重启刷新索引）。
- 工具元信息外部化（配置文件/DB 表定义 description）。
- 基于实际使用频率动态调整工具优先级。
- 支持工具分类标签辅助检索。
