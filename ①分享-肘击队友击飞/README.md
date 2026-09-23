# L4D2 Shove Launch / 肘击队友击飞

幸存者用 **推开（肘击）** 命中队友时，把队友**击飞**（带"被炸飞"的翻滚动画）；
命中**普通小僵尸**保持原版推开；命中**特感 / 坦克**可以各自开关。
A SourceMod plugin for L4D2: shoving a teammate launches them into the air (with the game's own
"blown away" animation), while common infected keep the vanilla shove.

---

## 依赖 Requirements

| 项目 | 要求 |
|---|---|
| 游戏 | Left 4 Dead 2（专用，L4D2 only） |
| SourceMod | 1.11+（实测 1.12.0.7253） |
| **[Left 4 DHooks Direct](https://forums.alliedmods.net/showthread.php?t=323220)** | **必需**（用到 `L4D2_CTerrorPlayer_Fling` / `L4D2Direct_DoAnimationEvent` / `AnimGetActivity`） |

## 安装 Install

1. `l4d2_shove_launch.smx` → `addons/sourcemod/plugins/`
2. 确认 `left4dhooks.smx` 已安装并加载（本插件加载时会报 native 缺失，如果没有）
3. 插件加载后会自动生成 `cfg/sourcemod/l4d2_shove_launch.cfg`（可直接改，改完 `sm plugins reload l4d2_shove_launch`）

## 参数 CVars

| cvar | 默认 | 说明 |
|---|---|---|
| `sm_shovelaunch_enable` | 1 | 总开关（0 = 完全恢复原版） |
| `sm_shovelaunch_teammates` | **1** | 肘击队友 → 击飞 |
| `sm_shovelaunch_si` | 0 | 肘击特感 → 击飞（0 = 原版只踉跄） |
| `sm_shovelaunch_tank` | 0 | 肘击坦克 → 击飞（0 = 原版） |
| `sm_shovelaunch_force` | 600.0 | 水平击飞速度（单位/秒） |
| `sm_shovelaunch_up` | 350.0 | 垂直上抛速度 |
| `sm_shovelaunch_message` | 1 | 给被击飞的真人一行提示 |
| `sm_shovelaunch_cooldown` | 0.2 | 同一目标两次击飞的最小间隔（秒） |
| `sm_shovelaunch_lift` | 8.0 | 起飞前先抬离地面多少单位（防速度被引擎清掉） |
| `sm_shovelaunch_bot_arc` | 1 | bot 兜底：沿抛物线搬运坐标 |
| `sm_shovelaunch_flyanim` | **2** | 飞行动画：0=不改 / 1=只发 76 号"被炸飞"动画事件 + 自己搬轨迹 / **2=调用引擎原生 Fling（动画+轨迹都像原版）** |
| `sm_shovelaunch_flyanim_repeat` | 1 | 模式 1 时飞行途中每 0.3 秒重发动画事件 |
| `sm_shovelaunch_physics` | **1** | 物理优先：每 tick 只设速度、坐标交给引擎积分（动画最连贯）；0 = 直接搬坐标 |
| `sm_shovelaunch_immune` | **1** | 飞行期间免伤（防队友被肘下高台摔死） |
| `sm_shovelaunch_debug` | 0 | 调试日志 |

## 命令 Commands

| 命令 | 权限 | 说明 |
|---|---|---|
| `sm_shovelaunch_status` | ADMFLAG_GENERIC | 查看当前设置 |
| `sm_shovelaunch_test <#userid\|名字>` | ROOT | 立刻对目标执行一次击飞（可对 bot） |
| `sm_shovelaunch_state <#userid\|名字>` | ROOT | 读回目标 血量/倒地/移动类型/坐标/速度/当前动画 |

## 实现说明 How it works

1. **只挂 `player_shoved` 事件**（`userid` = 被推的人、`attacker` = 推的人）。
   普通小僵尸不是玩家、走的是 `entity_shoved` → 插件完全不碰 → **天然保持原版推开**。
2. **飞行 = 物理优先**：每 tick 只 `TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel)`（只设速度、不动坐标），
   位置由引擎积分（带碰撞/重力）；竖直分量按抛物线 `vz = up - 800*t`。
   这样动画状态机看到的是**真实速度**，姿势连贯（原来每 tick 硬搬坐标会"一卡一卡"）。
   如果目标的**速度被机器人 AI / 踉跄状态吞掉**（0.12 秒位移 < 40 单位），自动退回
   "沿抛物线搬运坐标"兜底（写日志 `物理推不动`），保证一定飞得出去。
3. **动画**：`flyanim 2` 调用引擎原生 `CTerrorPlayer::Fling`（动画事件号 **76 = "got bounced"**），
   动画和轨迹都接近原版"被炸飞"；`flyanim 1` 只发 76 号动画事件、轨迹由插件搬；`0` 不改动画。
4. **免伤**：飞行期间（+ 落地后 0.6 秒；只要人还在空中就继续挡，最多护到起飞后 8 秒）
   用 `SDKHook_OnTakeDamage` 挡伤害。

## 已知注意事项 Notes

- **bot 的速度会被机器人 AI 清掉**，所以才有抛物线兜底；真人一般用物理速度就够。
- SourceMod 自带的 `sm_slap` **不走 `SDKHook_OnTakeDamage`**，拿它测"免伤"会误判成失效。
- **SourceMod 生成插件 cfg 时会沿用"同名 cvar 上一个版本登记的默认值"**：
  如果你改了某个 cvar 的**默认值**（不是改逻辑），生成的 cfg 里可能还是旧默认值 → 要么换个 cvar 名，要么手改 cfg。
- 本插件假定服务器是 **100 tick**（`vz` 用固定重力 800 推的抛物线；其他 tickrate 也能用，只是手感略不同）。
- 需要 `sdkhooks`；`sm_shovelaunch_state` 依赖 Left4DHooks 的 `AnimGetActivity` 显示动画名。

## 鸣谢 Credits

- [Left 4 DHooks Direct](https://forums.alliedmods.net/showthread.php?t=323220)（SilvDev）提供引擎 native；
  "76 号动画事件 = got bounced" 与 `CTerrorPlayer::Fling` 的调用方式参考其实现。
- 灵感来自原版坦克拳 / Charger 撞击的击飞表现。

## 版本 Changelog

| 版本 | 变化 |
|---|---|
| 1.0.0 | 初版：`player_shoved` + 速度击飞 |
| 1.0.1–1.0.2 | bot 速度被引擎清掉 → 抬离地面 + 抛物线搬运兜底 |
| 1.0.3 | 抛物线步进 0.05s → 0.01s（修"人物模型一卡一卡"） |
| 1.0.4–1.0.6 | 接入 Left4DHooks `Fling` / 动画事件 76（"被炸飞"动画）；新增 `flyanim` 开关 |
| 1.0.7 | 实测真实肘击上下文里引擎给的速度会被吞 → 位移改由插件保证（看门狗） |
| 1.0.8–1.0.9 | 改为**只设速度的物理飞行**（动画连贯）+ 飞行免伤；补 0.12 秒看门狗兜底 |
| 1.0.10 | 修 `FindTargetSafe`（服务器控制台执行不再抛 `No matching client` 语言短语异常） |
| 1.0.11 | 源码头部加入许可声明（**行为无变化**，仅注释与版本号） |

## 许可 License

**可自由使用 / 修改 / 转发，注明出处即可。**
Free to use, modify and redistribute, as long as credit is given.

（出处示例：`L4D2 Shove Launch by DSH`）
