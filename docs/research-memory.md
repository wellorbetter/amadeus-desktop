# Memory 架构调研（2026-08）

## 1. 前沿论文

### SimpleMem（ICML 2026，推荐采用）
- 核心：**语义无损压缩**（semantic lossless compression）三阶段管道：
  1. 语义压缩（intra-session 去冗余）
  2. 在线语义合成（跨会话合并为统一抽象表示）
  3. 意图感知检索规划（intent-aware retrieval planning）
- 效果：F1 +26.4%，推理 token 消耗最多降 **30 倍**，检索效率与成本显著优于基线
- 结论：**采用其"压缩-合成-意图检索"作为本项目的记忆管道**

### Mem0（arXiv:2504.19413）
- 模式："提取 → 存储 → 检索 → 注入"，语义检索 + 图（Pro）；托管/开源库两种形态
- 结论：借鉴其**分层记忆（短期会话 / 长期持久）+ 事实提取**做法；不自建复杂记忆平台

### Letta / MemGPT
- 模式：LLM 上下文当"虚拟内存"，OS 式分层（main / archival / recall），agent 主动换页
- 结论：概念参考（分层上下文管理），但运行时过重，不适合本地轻量产品

### MIRIX（2026）
- 六类记忆组件 + 多 agent 路由更新/检索
- 结论：参考"记忆类型划分"（episodic / semantic / procedural / summary）

## 2. 检索与成本对照（结论）
- 长上下文 vs 记忆系统：约 10 轮交互后记忆系统累计成本更低（100k 上下文场景）
- token 浪费：实测 30k tokens/消息 中 80% 冗余；缓存命中成本可降 ~75%（DeepSeek 缓存命中 0.02 元/M vs 未命中 1 元/M）
- 教训：**system prompt 稳定 + 摘要复用 → 吃满缓存价**；意图感知检索 → 只取相关切片

## 3. 向量数据库选型（结论）
| 方案 | 场景 | 结论 |
|---|---|---|
| sqlite-vec | 本地桌面 | ✅ 嵌入式、零依赖、挂载 time.db |
| Cloudflare Vectorize | 云端 | ✅ 与 Worker 同生态、按量付费、多租户隔离 |
| Qdrant / Weaviate / Pinecone | 自托管 | ❌ 运维重 / 贵 |
| pgvector | 云端 | ❌ 需 Postgres（D1 不适用） |

## 4. 本项目的落地映射
- Episodic 事实 → 现有 `usage_sessions` / `page_visits`（SQLite，精确查询）
- Semantic 记忆 → AI 提取的事实/偏好，embedding 存 sqlite-vec（本地）/ Vectorize（云端）
- Summary 分层 → 天/周/月摘要增量合成（SimpleMem 在线合成），KV/D1 缓存
- Procedural → trigger 策略 + 用户反馈（JSON 配置，规则引擎）
- 检索 → 双通道：结构化过滤（时间/应用）+ 语义相似度；按意图选择通道
