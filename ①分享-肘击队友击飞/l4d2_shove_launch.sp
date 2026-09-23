/**
 * L4D2 Shove Launch (肘击队友击飞)
 *
 * 幸存者肘击(推开)命中队友 -> 击飞(带引擎"被炸飞"动画);
 * 命中普通小僵尸保持原版推开; 命中特感/坦克可各自开关。
 *
 * 依赖: SourceMod 1.11+ / Left 4 DHooks Direct (必需)
 * 实测: L4D2 2.2.4.3, SourceMod 1.12.0.7253, Left4DHooks 1.127
 *
 * 许可: 可自由使用 / 修改 / 转发, 注明出处即可。
 * License: free to use, modify and redistribute, as long as credit is given.
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.11"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_TANK       8

// L4D2 里 PlayerAnimEvent_t == 76 就是"被撞飞/被炸飞"那个飞行动画。
// 依据: Left4DHooks 自己的 L4D2_CTerrorPlayer_Fling 实现里就是
//   SDKCall(g_hSDK_CTerrorPlayer_Fling, client, vDir, 76, attacker, 3.0)
// 注释写明 "76 is the 'got bounced' animation in L4D2"。
#define ANIM_EVENT_GOT_BOUNCED 76

// 物理优先飞行时, 先给物理 0.12 秒机会; 位移不到这个数就认定"速度被吞了", 改用抛物线搬运兜底
#define MOVE_CHECK_DELAY 0.12
#define MOVE_CHECK_MIN   40.0

ConVar g_cvEnable;
ConVar g_cvTeammates;
ConVar g_cvSI;
ConVar g_cvTank;
ConVar g_cvForce;
ConVar g_cvUp;
ConVar g_cvMessage;
ConVar g_cvCooldown;
ConVar g_cvLift;
ConVar g_cvBotArc;
ConVar g_cvFlyAnim;
ConVar g_cvAnimRepeat;
ConVar g_cvPhysics;
ConVar g_cvImmune;
ConVar g_cvDebug;

float g_flLastLaunch[MAXPLAYERS + 1];
bool  g_bFlying[MAXPLAYERS + 1];
float g_flImmuneUntil[MAXPLAYERS + 1];
float g_flImmuneStart[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = "L4D2 Shove Launch (肘击队友击飞)",
	author      = "DSH",
	description = "幸存者肘击(推开)命中队友 -> 击飞(带被炸飞动画); 命中普通小僵尸保持原版推开; 命中特感/坦克可切换",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("sm_shovelaunch_enable", "1",
		"1=开启肘击击飞 0=关闭(全部恢复原版)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTeammates = CreateConVar("sm_shovelaunch_teammates", "1",
		"1=肘击队友时把队友击飞 0=原版(只轻推)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSI = CreateConVar("sm_shovelaunch_si", "0",
		"肘击特感(胖子/舌头/猎人/骑乘/冲撞/口水): 1=击飞 0=原版(只踉跄)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTank = CreateConVar("sm_shovelaunch_tank", "0",
		"肘击坦克: 1=击飞 0=原版", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvForce = CreateConVar("sm_shovelaunch_force", "600.0",
		"击飞的水平速度(单位/秒), 原版坦克拳大约 500-700", FCVAR_NOTIFY, true, 0.0, true, 5000.0);
	g_cvUp = CreateConVar("sm_shovelaunch_up", "350.0",
		"击飞的垂直上抛速度(单位/秒)", FCVAR_NOTIFY, true, 0.0, true, 5000.0);
	g_cvMessage = CreateConVar("sm_shovelaunch_message", "1",
		"1=给被击飞的真人发一行提示 0=不提示", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCooldown = CreateConVar("sm_shovelaunch_cooldown", "0.2",
		"同一个人两次击飞之间的最小间隔(秒), 防止一次肘击触发多次", FCVAR_NOTIFY, true, 0.0, true, 5.0);
	g_cvLift = CreateConVar("sm_shovelaunch_lift", "8.0",
		"击飞时先把目标抬离地面多少单位(0=不抬)。抬离地面后引擎才不会清掉击飞速度, bot 才飞得起来", FCVAR_NOTIFY, true, 0.0, true, 64.0);
	g_cvBotArc = CreateConVar("sm_shovelaunch_bot_arc", "1",
		"1=被击飞的是 bot 时, 直接沿抛物线搬运它的位置(速度会被机器人 AI 清掉, 只有这招对 bot 有效) 0=只设速度", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	// 注意: 这两个 cvar 的旧名字 sm_shovelaunch_anim / _anim_repeat 在 v1.0.4/1.0.5 用过。
	// SourceMod 生成插件 cfg 时会沿用"上一个版本注册时记下的说明和默认值"(实测 2026-09-22:
	// 新版本默认明明是 2, 生成的 cfg 里却写 Default "1"), 换个新名字才会重新登记, 所以改名。
	g_cvFlyAnim = CreateConVar("sm_shovelaunch_flyanim", "2",
		"飞行动画: 0=不改(站着飞) 1=播放 76 号\"被炸飞\"动画事件 + 插件轨迹 2=引擎原生 Fling 动画(最像真炸飞)+ 位移由插件保证(推荐) 默认 2",
		FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cvAnimRepeat = CreateConVar("sm_shovelaunch_flyanim_repeat", "1",
		"动画模式 1 时, 飞行途中每隔 0.3 秒重发一次飞行动画事件, 免得姿势中途变回站立 1=开 0=只发一次", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvPhysics = CreateConVar("sm_shovelaunch_physics", "1",
		"1=物理优先(每 tick 只设速度, 坐标交给引擎积分, 动画最连贯; 0.12 秒没推动才改用抛物线搬运) 0=直接抛物线搬运坐标(旧行为)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvImmune = CreateConVar("sm_shovelaunch_immune", "1",
		"1=被击飞期间免伤(挡住摔落/子弹/特感伤害, 免得队友被肘飞后摔死或倒地) 0=不免伤", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("sm_shovelaunch_debug", "0",
		"1=写调试日志(每次肘击命中的目标类型与处理结果) 0=不写", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	// 普通小僵尸不是"玩家", 肘击它们走的是 entity_shoved 事件, 本插件完全不碰 -> 保持原版推开
	HookEvent("player_shoved", Event_PlayerShoved, EventHookMode_Post);

	AutoExecConfig(true, "l4d2_shove_launch");

	RegAdminCmd("sm_shovelaunch_status", Cmd_Status, ADMFLAG_GENERIC, "查看肘击击飞插件的设置");
	RegAdminCmd("sm_shovelaunch_test", Cmd_Test, ADMFLAG_ROOT, "对目标立刻执行一次击飞(测试用, 可对 bot 用)");
	RegAdminCmd("sm_shovelaunch_state", Cmd_State, ADMFLAG_ROOT, "读回目标的状态(血量/倒地/移动类型/坐标/速度/动画)");

	char animDef[8];
	GetConVarDefault(g_cvFlyAnim, animDef, sizeof(animDef));
	// 插件重载时已经在线的人不会走 OnClientPutInServer, 这里补挂一次免伤钩子
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage_Flung);
			g_flImmuneUntil[i] = 0.0;
			g_flImmuneStart[i] = 0.0;
		}
	}

	LogMessage("[SHOVELAUNCH] 插件 v%s 已加载 (team=%d si=%d tank=%d force=%.0f up=%.0f lift=%.1f flyanim=%d 登记默认=%s physics=%d immune=%d)",
		PLUGIN_VERSION, g_cvTeammates.BoolValue, g_cvSI.BoolValue, g_cvTank.BoolValue,
		g_cvForce.FloatValue, g_cvUp.FloatValue, g_cvLift.FloatValue, g_cvFlyAnim.IntValue, animDef,
		g_cvPhysics.BoolValue, g_cvImmune.BoolValue);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage_Flung);
	g_flImmuneUntil[client] = 0.0;
	g_flImmuneStart[client] = 0.0;
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage_Flung);
	g_bFlying[client] = false;
	g_flLastLaunch[client] = 0.0;
	g_flImmuneUntil[client] = 0.0;
	g_flImmuneStart[client] = 0.0;
}

public void Event_PlayerShoved(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
	{
		return;
	}

	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));

	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || !IsPlayerAlive(victim))
	{
		return;
	}
	if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker) || !IsPlayerAlive(attacker))
	{
		return;
	}
	if (GetClientTeam(attacker) != TEAM_SURVIVOR)
	{
		return;
	}

	int vteam = GetClientTeam(victim);
	bool launch = false;
	char kind[16];

	if (vteam == TEAM_SURVIVOR)
	{
		launch = g_cvTeammates.BoolValue;
		strcopy(kind, sizeof(kind), "队友");
	}
	else if (vteam == TEAM_INFECTED)
	{
		int zclass = GetEntProp(victim, Prop_Send, "m_zombieClass");

		if (zclass == ZC_TANK)
		{
			launch = g_cvTank.BoolValue;
			strcopy(kind, sizeof(kind), "坦克");
		}
		else
		{
			launch = g_cvSI.BoolValue;
			strcopy(kind, sizeof(kind), "特感");
		}
	}
	else
	{
		return;
	}

	if (!launch)
	{
		if (g_cvDebug.BoolValue)
		{
			LogMessage("[SHOVELAUNCH] %N 肘击 %N (%s) -> 按原版处理", attacker, victim, kind);
		}
		return;
	}

	if (LaunchPlayer(victim, attacker) && g_cvDebug.BoolValue)
	{
		LogMessage("[SHOVELAUNCH] %N 肘击 %N (%s) -> 击飞 (水平%.0f 上抛%.0f bot=%d anim=%d)",
			attacker, victim, kind, g_cvForce.FloatValue, g_cvUp.FloatValue, IsFakeClient(victim), g_cvFlyAnim.IntValue);
	}
}

/* 把目标沿"攻击者 -> 目标"方向击飞: 水平 force + 垂直 up
   竖直分量很关键: 目标离地后就没有地面摩擦, 速度才保得住 */
bool LaunchPlayer(int victim, int attacker)
{
	float now = GetGameTime();
	float cd = g_cvCooldown.FloatValue;

	if (cd > 0.0 && (now - g_flLastLaunch[victim]) < cd)
	{
		return false;
	}
	g_flLastLaunch[victim] = now;

	float vPos[3], aPos[3], dir[3];
	GetClientAbsOrigin(victim, vPos);
	GetClientAbsOrigin(attacker, aPos);

	dir[0] = vPos[0] - aPos[0];
	dir[1] = vPos[1] - aPos[1];
	dir[2] = 0.0;

	float len = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1]);

	if (len < 1.0)
	{
		// 两个人重叠/距离为 0 -> 用攻击者面朝方向
		float ang[3], fwd[3];
		GetClientEyeAngles(attacker, ang);
		GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
		dir[0] = fwd[0];
		dir[1] = fwd[1];
		dir[2] = 0.0;
		len = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1]);

		if (len < 0.001)
		{
			dir[0] = 1.0;
			dir[1] = 0.0;
			len = 1.0;
		}
	}

	dir[0] /= len;
	dir[1] /= len;

	// 飞行时长 = 上抛速度来回的时间(重力 800), 至少 0.5 秒
	DoLaunch(victim, attacker, dir, vPos);
	return true;
}

/* 真正执行击飞。attacker 可以等于 victim(控制台测试时没有第二个玩家)。 */
void DoLaunch(int victim, int attacker, const float dir[3], const float vPos[3])
{
	// 飞行时长 = 上抛速度来回的时间(重力 800), 至少 0.5 秒
	float airTime = 2.0 * g_cvUp.FloatValue / 800.0;
	if (airTime < 0.5)
	{
		airTime = 0.5;
	}

	int anim = g_cvFlyAnim.IntValue;

	if (g_cvMessage.BoolValue && !IsFakeClient(victim))
	{
		PrintToChat(victim, "\x04[肘击]\x01 你被队友肘飞了！");
	}

	// ---- 动画模式 2: 借引擎原生 Fling 播"被炸飞"动画 ----
	// ⚠️ 实测(09-22 13:0x 用户实战): 在**真实肘击**的上下文里, 引擎给的击飞速度会被吞掉,
	// 动画放了但人不动("动画对了, 就是不飞")。所以这里只借它的动画, 位移交给 MoveVictim(),
	// 并在 0.12 秒后检查一次: 引擎真推动了就用引擎的, 没推动就由插件兜底搬。
	if (anim >= 2)
	{
		float fvel[3];
		fvel[0] = dir[0] * g_cvForce.FloatValue;
		fvel[1] = dir[1] * g_cvForce.FloatValue;
		fvel[2] = g_cvUp.FloatValue;

		L4D2_CTerrorPlayer_Fling(victim, attacker, fvel);

		g_bFlying[victim] = true;
		CreateTimer(airTime + 0.6, Timer_FlingFix, GetClientUserId(victim));

		if (g_cvDebug.BoolValue)
		{
			LogMessage("[SHOVELAUNCH] %N 走引擎原生 Fling 动画: vel(%.0f %.0f %.0f)", victim, fvel[0], fvel[1], fvel[2]);
		}
		LogState("fling0", victim);
		ScheduleSamples(victim, airTime);

		if (g_cvPhysics.BoolValue)
		{
			StartFlight(victim, dir, vPos, GetGameTime());
		}
		else
		{
			MoveVictim(victim, dir, vPos, GetGameTime());
		}
		return;
	}

	// ---- 动画模式 1 (及 0): 轨迹由本插件负责, 只是额外播放"被炸飞"动画 ----
	if (anim >= 1)
	{
		PlayFlyAnim(victim);

		if (g_cvAnimRepeat.BoolValue)
		{
			DataPack dp = new DataPack();
			dp.WriteCell(GetClientUserId(victim));
			dp.WriteFloat(GetGameTime() + airTime);
			CreateTimer(0.3, Timer_FlyAnim, dp, TIMER_REPEAT);
		}
	}

	if (g_cvPhysics.BoolValue)
	{
		StartFlight(victim, dir, vPos, GetGameTime());
		return;
	}

	MoveVictim(victim, dir, vPos, GetGameTime());
}

/* 位移(旧行为: 直接搬坐标): bot 走抛物线搬运, 真人走"抬离地面 + 设速度" */
void MoveVictim(int victim, const float dir[3], const float vPos[3], float t0)
{
	// v1.0.2: 目标是 bot 时走"抛物线搬运"。实测(09-22)对站着的幸存者 bot,
	// 无论 teleport 设速度还是抬离地面, 速度都仍会被引擎/机器人 AI 清掉
	// (0.2 秒后 speed=0) -> 只能用直接搬位置的笨办法, 但它是唯一对 bot 有效的。
	if (g_cvBotArc.BoolValue && IsFakeClient(victim))
	{
		LaunchBotArc(victim, dir, vPos, t0);

		if (g_cvDebug.BoolValue)
		{
			LogMessage("[SHOVELAUNCH] %N (bot) 走抛物线搬运: 水平%.0f 上抛%.0f", victim, g_cvForce.FloatValue, g_cvUp.FloatValue);
		}
		return;
	}

	ApplyHumanVelocity(victim, dir, vPos);
}

/* ============================ 物理优先飞行 (v1.0.8) ============================
   用户反馈"飞的动画不连贯", 根因是旧做法**每 tick 直接改坐标**(20Hz→100Hz 都还是改坐标):
   位置被硬搬, 引擎里的速度是 0, 动画状态机就不知道人在飞 -> 姿势一卡一卡、不连续。
   现在改成: 每 tick 只**设速度**(坐标不动, 交给引擎自己积分 + 碰撞 + 重力),
   动画状态机看到的是真实速度 -> 姿势连贯。如果目标被机器人 AI/踉跄状态吞掉速度
   (0.12 秒位移不到 40 单位), 再退回抛物线搬运兜底, 保证一定飞得出去。 */
void StartFlight(int victim, const float dir[3], const float vPos[3], float t0)
{
	// 先抬离地面一点点: 站在地上时速度会被引擎/机器人 AI 清掉
	float pos[3];
	pos[0] = vPos[0];
	pos[1] = vPos[1];
	pos[2] = vPos[2] + g_cvLift.FloatValue;

	float vel[3];
	vel[0] = dir[0] * g_cvForce.FloatValue;
	vel[1] = dir[1] * g_cvForce.FloatValue;
	vel[2] = g_cvUp.FloatValue;

	TeleportEntity(victim, pos, NULL_VECTOR, vel);

	// 免伤窗口: 飞完 + 落地后 0.6 秒; 只要人还在空中就继续免伤
	// (被肘下高楼/飞过缺口时, 免得队友直接摔死)
	if (g_cvImmune.BoolValue)
	{
		float airTime = 2.0 * g_cvUp.FloatValue / 800.0;
		if (airTime < 0.5)
		{
			airTime = 0.5;
		}
		g_flImmuneStart[victim] = t0;
		g_flImmuneUntil[victim] = t0 + airTime + 0.6;
	}

	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(victim));
	dp.WriteFloat(dir[0]);
	dp.WriteFloat(dir[1]);
	dp.WriteFloat(vPos[0]);
	dp.WriteFloat(vPos[1]);
	dp.WriteFloat(vPos[2]);
	dp.WriteFloat(t0);
	CreateTimer(0.01, Timer_Flight, dp, TIMER_REPEAT);

	if (g_cvDebug.BoolValue)
	{
		LogMessage("[SHOVELAUNCH] %N 走物理飞行(只设速度): 水平%.0f 上抛%.0f", victim, g_cvForce.FloatValue, g_cvUp.FloatValue);
	}
}

public Action Timer_Flight(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	float dx = dp.ReadFloat();
	float dy = dp.ReadFloat();
	float sx = dp.ReadFloat();
	float sy = dp.ReadFloat();
	float sz = dp.ReadFloat();
	float t0 = dp.ReadFloat();

	int client = GetClientOfUserId(userid);

	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return Plugin_Stop;
	}

	float t = GetGameTime() - t0;
	float up = g_cvUp.FloatValue;
	float total = 2.0 * up / 800.0;

	if (total < 0.5)
	{
		total = 0.5;
	}

	if (t < 0.0 || t > total)
	{
		return Plugin_Stop;
	}

	// 看门狗: 物理推不动(速度被吞)就退回抛物线搬运
	if (t >= MOVE_CHECK_DELAY)
	{
		float cur[3];
		GetClientAbsOrigin(client, cur);

		float mx = cur[0] - sx, my = cur[1] - sy, mz = cur[2] - sz;
		float moved = SquareRoot(mx * mx + my * my + mz * mz);

		if (moved < MOVE_CHECK_MIN)
		{
			LogMessage("[SHOVELAUNCH] %N 物理推不动(0.12 秒只走了 %.0f) -> 改用抛物线搬运兜底", client, moved);

			float dir[3], start[3];
			dir[0] = dx; dir[1] = dy; dir[2] = 0.0;
			start[0] = sx; start[1] = sy; start[2] = sz;

			if (g_cvBotArc.BoolValue && IsFakeClient(client))
			{
				LaunchBotArc(client, dir, start, t0);
			}
			else
			{
				ApplyHumanVelocity(client, dir, start);
			}
			return Plugin_Stop;
		}
	}

	// 只设速度, 不改坐标: 位置由引擎积分 -> 客户端看到的和正常移动/被炸飞一样, 动画连贯
	float vel[3];
	vel[0] = dx * g_cvForce.FloatValue;
	vel[1] = dy * g_cvForce.FloatValue;
	vel[2] = up - 800.0 * t;

	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
	return Plugin_Continue;
}

/* 飞行期间免伤: 摔落/子弹/特感伤害全部挡掉, 免得队友被肘飞后摔死或倒地 */
public Action OnTakeDamage_Flung(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!g_cvImmune.BoolValue || victim <= 0 || victim > MaxClients)
	{
		return Plugin_Continue;
	}

	float now = GetGameTime();
	bool inWindow = (g_flImmuneUntil[victim] > now);
	// 还在空中也继续免伤(最多护到起飞后 8 秒), 免得被肘下楼摔死
	bool airborne = (g_flImmuneStart[victim] > 0.0) && (now < g_flImmuneStart[victim] + 8.0)
		&& !(GetEntityFlags(victim) & FL_ONGROUND);

	if (inWindow || airborne)
	{
		if (g_cvDebug.BoolValue)
		{
			LogMessage("[SHOVELAUNCH] %N 飞行免伤: 挡掉 %.1f 点伤害 (type %d)", victim, damage, damagetype);
		}
		damage = 0.0;
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

/* 真人(或关掉 bot 抛物线时): 先把目标抬离地面一点点再设速度。
   v1.0.1 实测: 站在地上时 TeleportEntity 设的速度会被引擎/机器人 AI 在同一 tick 清掉
   (0.2 秒后读回 speed=0); 只要目标离开地面就变成"空中移动", 引擎不再清速度。 */
void ApplyHumanVelocity(int victim, const float dir[3], const float vPos[3])
{
	float vel[3];
	vel[0] = dir[0] * g_cvForce.FloatValue;
	vel[1] = dir[1] * g_cvForce.FloatValue;
	vel[2] = g_cvUp.FloatValue;

	float pos[3];
	pos[0] = vPos[0];
	pos[1] = vPos[1];
	pos[2] = vPos[2] + g_cvLift.FloatValue;

	TeleportEntity(victim, pos, NULL_VECTOR, vel);
}

/* 播放引擎自带的"被击飞/被炸飞"动画(76 号 PlayerAnimEvent) */
void PlayFlyAnim(int client)
{
	L4D2Direct_DoAnimationEvent(client, ANIM_EVENT_GOT_BOUNCED);
}

public Action Timer_FlyAnim(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	float endTime = dp.ReadFloat();

	int client = GetClientOfUserId(userid);

	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client) || GetGameTime() > endTime)
	{
		return Plugin_Stop;
	}

	PlayFlyAnim(client);
	return Plugin_Continue;
}

/* 引擎 Fling 之后兜底: 万一目标还飘在空中没落地, 把它拉回正常行走状态 */
public Action Timer_FlingFix(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);

	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return Plugin_Stop;
	}

	g_bFlying[client] = false;

	MoveType mt = GetEntityMoveType(client);

	if (mt != MOVETYPE_WALK && mt != MOVETYPE_NONE)
	{
		float pos[3], zero[3];
		GetClientAbsOrigin(client, pos);
		SetEntityMoveType(client, MOVETYPE_WALK);
		TeleportEntity(client, pos, NULL_VECTOR, zero);
		LogMessage("[SHOVELAUNCH] %N Fling 结束兜底: movetype %d -> WALK", client, view_as<int>(mt));
	}
	return Plugin_Stop;
}

void ScheduleSamples(int victim, float airTime)
{
	float marks[3];
	marks[0] = 0.25;
	marks[1] = airTime * 0.5;
	marks[2] = airTime + 0.5;

	for (int i = 0; i < 3; i++)
	{
		DataPack dp = new DataPack();
		dp.WriteCell(GetClientUserId(victim));
		dp.WriteFloat(marks[i]);
		CreateTimer(marks[i], Timer_Sample, dp);
	}
}

public Action Timer_Sample(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	float at = dp.ReadFloat();

	int client = GetClientOfUserId(userid);

	char tag[32];
	Format(tag, sizeof(tag), "+%.2fs", at);
	LogState(tag, client);
	return Plugin_Stop;
}

/* bot 专用: 沿抛物线直接搬运位置。
   为什么不能只设速度: 实测对站着的幸存者 bot, TeleportEntity 设的速度会被
   机器人 AI 在同一 tick 清掉(读回 speed=0), 抬离地面也没用 -> 只能搬位置。
   t0 = 起飞时刻: 兜底是从半路接手的, 传原始起飞时刻, 抛物线相位才对得上。 */
void LaunchBotArc(int victim, const float dir[3], const float startPos[3], float t0)
{
	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(victim));
	dp.WriteFloat(dir[0]);
	dp.WriteFloat(dir[1]);
	dp.WriteFloat(startPos[0]);
	dp.WriteFloat(startPos[1]);
	dp.WriteFloat(startPos[2]);
	dp.WriteFloat(t0);
	dp.WriteFloat(g_cvForce.FloatValue);
	dp.WriteFloat(g_cvUp.FloatValue);
	// v1.0.3: 步进 0.05 秒 -> 0.01 秒(100 tick 服务器 = 每 tick 搬一步)。
	// 原来 20Hz 一步要挪 30 单位, 客户端看到的就是"一卡一卡"; 现在每步约 6 单位,
	// 和正常走路一个 tick 的位移相当, 模型就顺了。
	CreateTimer(0.01, Timer_BotArc, dp, TIMER_REPEAT);
}

public Action Timer_BotArc(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	float dx = dp.ReadFloat();
	float dy = dp.ReadFloat();
	float sx = dp.ReadFloat();
	float sy = dp.ReadFloat();
	float sz = dp.ReadFloat();
	float t0 = dp.ReadFloat();
	float force = dp.ReadFloat();
	float up = dp.ReadFloat();

	int client = GetClientOfUserId(userid);

	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client) || !IsFakeClient(client))
	{
		return Plugin_Stop;
	}

	float t = GetGameTime() - t0;
	float total = (up > 0.0) ? (2.0 * up / 800.0) : 0.4;

	if (t > total || t < 0.0)
	{
		return Plugin_Stop;
	}

	float dest[3];
	dest[0] = sx + dx * force * t;
	dest[1] = sy + dy * force * t;
	dest[2] = sz + up * t - 0.5 * 800.0 * t * t + 2.0;   // 抛物线(+2 免得贴地)

	float cur[3];
	GetClientAbsOrigin(client, cur);

	// 撞墙就停下, 不让 bot 穿墙
	float mins[3], maxs[3];
	mins[0] = -13.0; mins[1] = -13.0; mins[2] = 0.0;
	maxs[0] =  13.0; maxs[1] =  13.0; maxs[2] = 72.0;

	TR_TraceHullFilter(cur, dest, mins, maxs, MASK_PLAYERSOLID, TraceFilter_NotSelf, client);
	if (TR_DidHit())
	{
		return Plugin_Stop;
	}

	float vel[3];
	vel[0] = dx * force;
	vel[1] = dy * force;
	vel[2] = up - 800.0 * t;

	TeleportEntity(client, dest, NULL_VECTOR, vel);
	return Plugin_Continue;
}

public bool TraceFilter_NotSelf(int entity, int contentsMask, any data)
{
	return entity != data;
}

void LogState(const char[] tag, int client)
{
	if (!g_cvDebug.BoolValue)
	{
		return;
	}
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		LogMessage("[SHOVELAUNCH][STATE %s] client 无效", tag);
		return;
	}

	float pos[3], vel[3];
	GetClientAbsOrigin(client, pos);
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
	float speed = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2]);

	int seq = GetEntProp(client, Prop_Send, "m_nSequence");
	char act[64];
	act[0] = '\0';
	AnimGetActivity(seq, act, sizeof(act));

	LogMessage("[SHOVELAUNCH][STATE %s] %N alive=%d hp=%d incap=%d movetype=%d seq=%d act=%s pos(%.0f %.0f %.0f) vel(%.0f %.0f %.0f) speed=%.0f",
		tag, client, IsPlayerAlive(client), GetClientHealth(client),
		GetEntProp(client, Prop_Send, "m_isIncapacitated"),
		view_as<int>(GetEntityMoveType(client)), seq, act,
		pos[0], pos[1], pos[2], vel[0], vel[1], vel[2], speed);
}

/* 自己的目标查找: 服务器控制台执行时 FindTarget 会因为缺语言文件报
   "Language phrase No matching client not found" 异常, 所以自己来 */
int FindTargetSafe(const char[] arg)
{
	if (arg[0] == '#')
	{
		int c = GetClientOfUserId(StringToInt(arg[1]));
		return (c > 0) ? c : 0;
	}

	char name[MAX_NAME_LENGTH];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}
		GetClientName(i, name, sizeof(name));
		if (StrEqual(name, arg, false))
		{
			return i;
		}
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}
		GetClientName(i, name, sizeof(name));
		if (StrContains(name, arg, false) != -1)
		{
			return i;
		}
	}
	return 0;
}

public Action Cmd_State(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[肘击击飞] 用法: sm_shovelaunch_state <#userid|名字>");
		return Plugin_Handled;
	}

	char arg[64];
	GetCmdArg(1, arg, sizeof(arg));
	int target = FindTargetSafe(arg);
	if (target <= 0)
	{
		ReplyToCommand(client, "[肘击击飞] 找不到目标: %s", arg);
		return Plugin_Handled;
	}

	float pos[3], vel[3];
	GetClientAbsOrigin(target, pos);
	GetEntPropVector(target, Prop_Data, "m_vecVelocity", vel);
	int seq = GetEntProp(target, Prop_Send, "m_nSequence");
	char act[64];
	act[0] = '\0';
	AnimGetActivity(seq, act, sizeof(act));

	ReplyToCommand(client, "[肘击击飞] %N bot=%d alive=%d hp=%d incap=%d movetype=%d seq=%d act=%s",
		target, IsFakeClient(target), IsPlayerAlive(target), GetClientHealth(target),
		GetEntProp(target, Prop_Send, "m_isIncapacitated"),
		view_as<int>(GetEntityMoveType(target)), seq, act);
	ReplyToCommand(client, "[肘击击飞] pos(%.0f %.0f %.0f) vel(%.0f %.0f %.0f)",
		pos[0], pos[1], pos[2], vel[0], vel[1], vel[2]);
	return Plugin_Handled;
}

public Action Cmd_Status(int client, int args)
{
	ReplyToCommand(client, "[肘击击飞] v%s enable=%d 队友=%d 特感=%d 坦克=%d 水平=%.0f 上抛=%.0f 抬升=%.1f bot抛物线=%d 动画=%d(0关/1动画事件/2引擎Fling) 动画重发=%d 物理优先=%d 飞行免伤=%d 提示=%d 冷却=%.2f",
		PLUGIN_VERSION, g_cvEnable.BoolValue, g_cvTeammates.BoolValue, g_cvSI.BoolValue,
		g_cvTank.BoolValue, g_cvForce.FloatValue, g_cvUp.FloatValue, g_cvLift.FloatValue,
		g_cvBotArc.BoolValue, g_cvFlyAnim.IntValue, g_cvAnimRepeat.BoolValue, g_cvPhysics.BoolValue,
		g_cvImmune.BoolValue, g_cvMessage.BoolValue, g_cvCooldown.FloatValue);
	ReplyToCommand(client, "[肘击击飞] 普通小僵尸: 始终原版推开(不是玩家, 走 entity_shoved, 插件不碰)");
	return Plugin_Handled;
}

public Action Cmd_Test(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[肘击击飞] 用法: sm_shovelaunch_test <#userid|名字>  (对目标直接执行一次击飞)");
		return Plugin_Handled;
	}

	char arg[64];
	GetCmdArg(1, arg, sizeof(arg));
	int target = FindTargetSafe(arg);
	if (target <= 0)
	{
		ReplyToCommand(client, "[肘击击飞] 找不到目标: %s", arg);
		return Plugin_Handled;
	}
	if (!IsPlayerAlive(target))
	{
		ReplyToCommand(client, "[肘击击飞] 目标不是活人");
		return Plugin_Handled;
	}

	if (client > 0 && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client))
	{
		bool ok = LaunchPlayer(target, client);
		ReplyToCommand(client, "[肘击击飞] 对 %N 执行击飞: %s (动画模式 %d)",
			target, ok ? "已执行" : "被冷却拦下", g_cvFlyAnim.IntValue);
		return Plugin_Handled;
	}

	// 控制台执行时没有攻击者 -> 用目标自己面朝的方向把他往前上方弹
	float ang[3], fwd[3];
	GetClientEyeAngles(target, ang);
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	fwd[2] = 0.0;

	float len = SquareRoot(fwd[0] * fwd[0] + fwd[1] * fwd[1]);
	if (len < 0.001)
	{
		fwd[0] = 1.0; fwd[1] = 0.0; len = 1.0;
	}
	fwd[0] /= len;
	fwd[1] /= len;

	float pos[3];
	GetClientAbsOrigin(target, pos);

	DoLaunch(target, target, fwd, pos);
	ReplyToCommand(client, "[肘击击飞] 已对 %N 执行击飞 (控制台执行, 方向=他自己面朝方向, 动画模式 %d)", target, g_cvFlyAnim.IntValue);
	return Plugin_Handled;
}
