# 开源素材可复用性评估（2026-08-08）

## 结论速览
| 素材 | 来源协议 | 能否直接拿 | 落地方式 |
|---|---|---|---|
| Kurisu_EN.md 人格 prompt | Amadeus 仓库 GPL-3.0 | ✅ 可吸收改写（私有仓库无分发义务） | 已改写进我方 soulmd（原创中文版） |
| Story_EN.md 世界观摘要 | 同上（衍生自 fandom wiki） | ⚠️ 改写可用 | 已做原创「世界观锚点」 |
| SG_Dialogues_EN.md VN 台词 | **MAGES/Nitroplus VN 版权** | ❌ 不入库 | 本地 gitignore 语料，仅个人使用 |
| emails.json D-mail 文本 | 同上 | ❌ | 不入库 |

## 法律要点
1. **timetrace-cloud 是私有仓库**（GitHub PRIVATE）：GPL-3.0 的义务在「分发」时触发；私有个人使用不构成分发，因此拿 GPL-3.0 的 prompt 改写没有合规压力。
2. **台词是游戏版权文本**（Steins;Gate VN，MAGES 版权）：即便托管在 GPL 仓库里，也不改变底层版权归属。直接 commit 进仓库（哪怕私有）仍有风险；若未来仓库转公开，会出问题。
3. **安全做法**：
   - 仓库内：只放**原创风格样本**（few-shot）与原创世界观锚点。
   - 本地：VN 台词语料放 gitignore 文件，由检索模块按需读取，仅个人使用。

## 落地清单
- [x] 原创风格样本 10 条 + 世界观锚点（`apps/pet-demo/soul/kurisu.md`）
- [x] 本地 VN 语料提取（`apps/pet-demo/agent/korisu-vn-corpus.json`，658 条，已 gitignore）
- [x] 风格检索模块（`apps/pet-demo/agent/style-retrieval.mjs`：关键词命中 trigger 场景 → 取 2-3 条注入）
- [x] 本地触发实测（`apps/api/scripts/trigger-demo.mjs`，6/6 场景输出成功）
- [x] 单元测试（`tests/style-retrieval.test.ts`，含语料缺失降级路径）
