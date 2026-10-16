#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hamsandwich>
#include <xs>
#include <nvault>

#pragma tabsize 0

/*
 *  v1.4  - FIX: lasermine planting bug (orphan entity leak + frozen player on failed plant)
 *        - Plant trace now starts at the eyes, rejects players/other mines, re-validates state
 *        - cvars bound with bind_pcvar_*, O(1) entity filter (pev_impulse tag) in Think/Touch/TraceLine
 *        - BarTime msg id resolved at runtime, g_deployed underflow guards
 */

// ============================================================================
//  MOD SECIMI - SADECE BIRINI AKTIF ET / 모드 선택 - 하나만 활성화
// ============================================================================
#define ZOMBIE_PLAGUE
//#define BIOHAZARD

#if defined ZOMBIE_PLAGUE
    #if defined BIOHAZARD
        #error ZOMBIE_PLAGUE ve BIOHAZARD ayni anda acik olamaz! Sadece birini ac. ZOMBIE_PLAGUE와 BIOHAZARD는 동시에 활성화할 수 없습니다! 둘 중 하나만 활성화하세요.
    #endif
#else
    #if !defined BIOHAZARD
        #error Mod secilmedi! ZOMBIE_PLAGUE veya BIOHAZARD define'lerinden birini ac. 선택된 모드가 없습니다! ZOMBIE_PLAGUE 또는 BIOHAZARD 정의를 활성화하십시오.
    #endif
#endif

#if defined BIOHAZARD
    #include <cstrike>
    #include <biohazard>
#else
    #include <zombieplague>
#endif

#if AMXX_VERSION_NUM < 180
    #assert AMX Mod X v1.8.0 or greater library required!
#endif

#if defined BIOHAZARD
    #define PLUGIN "[BIO] LaserMine"
#else
    #define PLUGIN "[ZP] LaserMine"
#endif
#define VERSION "1.4"
#define AUTHOR "Merhabalarr"

#if defined BIOHAZARD
    #define MOD_TAG "Biohazard Lasermine"
#else
    #define MOD_TAG "Zombie Plague Lasermine"
#endif

#define RemoveEntity(%1)    engfunc(EngFunc_RemoveEntity,%1)
#define TASK_PLANT            15100
#define TASK_RESET            15500
#define TASK_RELEASE        15900

#define LASERMINE_TEAM        pev_iuser1 
#define LASERMINE_OWNER        pev_iuser2 
#define LASERMINE_STEP        pev_iuser3
#define LASERMINE_HITING    pev_iuser4
#define LASERMINE_COUNT        pev_fuser1

#define LASERMINE_POWERUP    pev_fuser2
#define LASERMINE_BEAMTHINK    pev_fuser3

#define LASERMINE_BEAMENDPOINT    pev_vuser1
#define MAX_MINES            10
#define LASERMINE_MAGIC        0x4C4D    // pev_impulse tag: O(1) "is this entity a lasermine?" check
#define PLANT_RANGE            128
#define MODE_LASERMINE        0
#define OFFSET_TEAM            114
#define OFFSET_MONEY        115
#define OFFSET_DEATH        444

#define cs_get_user_team(%1)    CsTeams:get_offset_value(%1,OFFSET_TEAM)
#define cs_get_user_deaths(%1)    get_offset_value(%1,OFFSET_DEATH)

#if !defined BIOHAZARD
native zp_is_assassin_round();
native zp_is_sniper_round();
native zp_is_armageddon_round();
native zp_is_apocalypse_round();
native zp_is_nightmare_round();

// ZP 4.3 / 4.4 / 4.5 ve ozel (assassin, sniper...) surumler: eksik native varsa plugin yuklenir, sadece o mod kontrol edilmez
new bool:g_has_assassin = true, bool:g_has_sniper = true, bool:g_has_armageddon = true
new bool:g_has_apocalypse = true, bool:g_has_nightmare = true

public plugin_natives()
{
    set_native_filter("ltm_native_filter")
}

public ltm_native_filter(const name[], index, trap)
{
    if(trap)
        return PLUGIN_CONTINUE

    if(equal(name, "zp_is_assassin_round"))        g_has_assassin = false
    else if(equal(name, "zp_is_sniper_round"))     g_has_sniper = false
    else if(equal(name, "zp_is_armageddon_round")) g_has_armageddon = false
    else if(equal(name, "zp_is_apocalypse_round")) g_has_apocalypse = false
    else if(equal(name, "zp_is_nightmare_round"))  g_has_nightmare = false
    else return PLUGIN_CONTINUE

    return PLUGIN_HANDLED
}
#endif

enum _:intenum
{
    iBanTime[MAX_PLAYERS+1],
    iPickPlayerr[MAX_PLAYERS+1]
};
new g_int[intenum];

enum (+= 1336)
{
    TASK_BAN = 1336
}

new const
    Red_Hum        = 0,
    Green_Hum     = 0,
    Blue_Hum    = 255;

new const
    Red_Zomb    = 255,
    Green_Zomb     = 0,
    Blue_Zomb    = 0;

enum tripmine_e {
    TRIPMINE_IDLE1 = 0,
    TRIPMINE_IDLE2,
    TRIPMINE_ARM1,
    TRIPMINE_ARM2,
    TRIPMINE_FIDGET,
    TRIPMINE_HOLSTER,
    TRIPMINE_DRAW,
    TRIPMINE_WORLD,
    TRIPMINE_GROUND,
};

enum
{
    POWERUP_THINK,
    BEAMBREAK_THINK,
    EXPLOSE_THINK
};

enum
{
    POWERUP_SOUND,
    ACTIVATE_SOUND,
    STOP_SOUND
};

new const
    ENT_MODELS[]    = "models/LaserMines/v_laser_mine.mdl",
    ENT_SOUND1[]    = "weapons/mine_deploy.wav",
    ENT_SOUND2[]    = "weapons/mine_charge.wav",
    ENT_SOUND3[]    = "weapons/mine_activate.wav",
    ENT_SOUND4[]    = "debris/beamstart9.wav",
    ENT_SOUND5[]    = "items/gunpickup2.wav",
    ENT_SOUND6[]    = "debris/bustglass1.wav",
    ENT_SOUND7[]    = "debris/bustglass2.wav",
    ENT_SPRITE1[]    = "sprites/laserbeam.spr",
    ENT_SPRITE2[]    = "sprites/zerogxplode.spr";

new const
    ENT_CLASS_NAME[]    =    "lasermine",
    ENT_CLASS_NAME3[]    =    "func_breakable",
    gSnarkClassName[]    =    "wpn_snark",
    barnacle_class[]    =    "barnacle",
    weapon_box[]        =    "weaponbox";

new g_EntMine, beam, boom
// Cvars bound with bind_pcvar_*: always-fresh plain variables, no get_pcvar_* call per read
new g_LENABLE, g_LFMONEY, g_LAMMO, g_LDMG, g_LBEO, g_LTMAX, g_LCOST, g_LHEALTH, g_LMODE, g_NOROUND
new g_LFF, g_LDELAY, g_LVISIBLE, g_LSTAMMO, g_LACCESS, g_LGLOW, g_LDMGMODE, g_LCLMODE
new g_LCBRIGHT, g_LDSEC, g_LCMDMODE, g_LBUYMODE, g_LHEALTHMODE;
new Float:g_LRADIUS, Float:g_LRDMG;
new g_LCBT; // string cvar (team restriction) - read on demand
new g_msgDeathMsg,g_msgScoreInfo,g_msgDamage,g_msgBarTime;
new g_dcount[33],g_nowtime,g_MaxPL
new bool:g_settinglaser[33]
new Float:plspeed[33], plsetting[33], g_havemine[33], g_deployed[33];

new g_vault;

#if defined BIOHAZARD
    #define DEFAULT_FRAGMONEY "1"
#else
    #define DEFAULT_FRAGMONEY "1"
#endif

stock bool:mod_is_zombie(id)
{
#if defined BIOHAZARD
    return bool:is_user_zombie(id);
#else
    return bool:zp_get_user_zombie(id);   // ZP 4.3 / 4.4 / 4.5
#endif
}

stock bool:mod_round_started()
{
#if defined BIOHAZARD
    return bool:game_started();
#else
    return bool:zp_has_round_started();
#endif
}

stock mod_get_ammo(id)
{
#if defined BIOHAZARD
    return cs_get_user_money(id);
#else
    return zp_get_user_ammo_packs(id);
#endif
}

stock mod_set_ammo(id, amount)
{
    if(amount < 0) amount = 0;
#if defined BIOHAZARD
    if(amount > 16000) amount = 16000;
    cs_set_user_money(id, amount, 1);
#else
    zp_set_user_ammo_packs(id, amount);
#endif
}

stock bool:mod_mode_blocked()
{
#if defined BIOHAZARD
    return false;
#else
    if(zp_is_plague_round() || zp_is_nemesis_round() || zp_is_survivor_round())
        return true;
    if(g_has_assassin && zp_is_assassin_round()) return true;
    if(g_has_sniper && zp_is_sniper_round()) return true;
    if(g_has_armageddon && zp_is_armageddon_round()) return true;
    if(g_has_apocalypse && zp_is_apocalypse_round()) return true;
    if(g_has_nightmare && zp_is_nightmare_round()) return true;
    return false;
#endif
}

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR);

    RegisterHam(Ham_TakeDamage, ENT_CLASS_NAME3, "Laser_TakeDamage")
    register_clcmd("+setlaser","CreateLaserMine_Progress_b");
    register_clcmd("-setlaser","StopCreateLaserMine");
    register_clcmd("+dellaser","ReturnLaserMine_Progress");
    register_clcmd("-dellaser","StopReturnLaserMine");
    register_clcmd("say","say_lasermine");
    register_clcmd("buy_lasermine","BuyLasermine");

    register_concmd("amx_lazersil", "admin_lazer_sil", ADMIN_RESERVATION, "<isim>")
    register_concmd("amx_ls", "admin_lazer_sil", ADMIN_RESERVATION, "<isim>")

    register_concmd("amx_lazersilmenu", "clcmd_lazersilmenu", ADMIN_RESERVATION, "<lazer silme menusunu acar>")
    register_concmd("amx_lsmenu", "clcmd_lazersilmenu", ADMIN_RESERVATION, "<lazer silme menusunu acar>")
    register_concmd("amx_lsm", "clcmd_lazersilmenu", ADMIN_RESERVATION, "<lazer silme menusunu acar>")

    register_concmd("amx_lazerban", "clcmd_lazerban", ADMIN_BAN, "<name> <saniye>, oyuncuya Lazer-Ban atar.");
    register_concmd("amx_lazerunban", "clcmd_lazerunban", ADMIN_BAN, "<name>, oyuncunun Lazer-Ban'ini kaldirir.");
    register_concmd("amx_lazerbanmenu", "clcmd_lazerbanmenu", ADMIN_BAN, "<lazer ban menusunu acar>");
    register_clcmd("SureBelirlee", "clcmd_SureBelirle");

    bind_pcvar_num(register_cvar("zp_ltm","1"), g_LENABLE)
    bind_pcvar_num(register_cvar("zp_ltm_acs","0"), g_LACCESS)
    bind_pcvar_num(register_cvar("zp_ltm_mode","0"), g_LMODE)
    bind_pcvar_num(register_cvar("zp_ltm_ammo","3"), g_LAMMO)
    bind_pcvar_num(register_cvar("zp_ltm_dmg","100"), g_LDMG)
    bind_pcvar_num(register_cvar("zp_ltm_cost","0"), g_LCOST)
    bind_pcvar_num(register_cvar("zp_ltm_fragmoney", DEFAULT_FRAGMONEY), g_LFMONEY)
    bind_pcvar_num(register_cvar("zp_ltm_health","5"), g_LHEALTH)
    bind_pcvar_num(register_cvar("zp_ltm_health_mode","0"), g_LHEALTHMODE)
    bind_pcvar_num(register_cvar("zp_ltm_teammax","200"), g_LTMAX)
    bind_pcvar_float(register_cvar("zp_ltm_radius","320.0"), g_LRADIUS)
    bind_pcvar_float(register_cvar("zp_ltm_rdmg","100"), g_LRDMG)
    bind_pcvar_num(register_cvar("zp_ltm_ff","0"), g_LFF)
    g_LCBT        = register_cvar("zp_ltm_cbt","ALL")
    bind_pcvar_num(register_cvar("zp_ltm_delay","0.1"), g_LDELAY)
    bind_pcvar_num(register_cvar("zp_ltm_line","3"), g_LVISIBLE)
    bind_pcvar_num(register_cvar("zp_ltm_glow","1"), g_LGLOW)
    bind_pcvar_num(register_cvar("zp_ltm_bright","100"), g_LCBRIGHT)
    bind_pcvar_num(register_cvar("zp_ltm_color","0"), g_LCLMODE)
    bind_pcvar_num(register_cvar("zp_ltm_ldmgmode","2"), g_LDMGMODE)
    bind_pcvar_num(register_cvar("zp_ltm_ldmgseconds","1"), g_LDSEC)
    bind_pcvar_num(register_cvar("zp_ltm_startammo","3"), g_LSTAMMO)
    bind_pcvar_num(register_cvar("zp_ltm_buymode","0"), g_LBUYMODE)
    bind_pcvar_num(register_cvar("zp_ltm_cmdmode","1"), g_LCMDMODE)
    bind_pcvar_num(register_cvar("zp_ltm_brokeenemy","0"), g_LBEO)
    bind_pcvar_num(register_cvar("zp_ltm_noround","1"), g_NOROUND)

    register_event("DeathMsg", "DeathEvent", "a");
    register_event("CurWeapon", "standing", "be", "1=1");
    register_event("ResetHUD", "delaycount", "a");
    register_event("ResetHUD", "newround", "b");
    register_event("Damage","CutDeploy_onDamage","b");
#if defined BIOHAZARD
    register_logevent("logevent_round_end", 2, "1=Round_End");
    register_logevent("logevent_round_end", 2, "1&Restart_Round_");
#endif
    g_msgDeathMsg    = get_user_msgid("DeathMsg");
    g_msgScoreInfo    = get_user_msgid("ScoreInfo");
    g_msgDamage        = get_user_msgid("Damage");
    g_msgBarTime    = get_user_msgid("BarTime");

    register_forward(FM_Think, "ltm_Think");
    register_forward(FM_PlayerPostThink, "ltm_PostThink");
    register_forward(FM_PlayerPreThink, "ltm_PreThink");
    register_forward(FM_TraceLine, "fw_TraceLine", 1);
    register_forward(FM_Touch, "ltm_Touch")

    register_dictionary("LaserMines.txt")
    register_dictionary("LaserMines_Extra.txt")
    register_cvar("Merhabalarr", "[ZP/BIO] LaserMines v1.4.0", FCVAR_SERVER|FCVAR_SPONLY)
}

public plugin_end()
{
    nvault_close(g_vault);
}

public plugin_precache()
{
    precache_sound(ENT_SOUND1);
    precache_sound(ENT_SOUND2);
    precache_sound(ENT_SOUND3);
    precache_sound(ENT_SOUND4);
    precache_sound(ENT_SOUND5);
    precache_sound(ENT_SOUND6);
    precache_sound(ENT_SOUND7);
    precache_model(ENT_MODELS);
    beam = precache_model(ENT_SPRITE1);
    boom = precache_model(ENT_SPRITE2);
    return PLUGIN_CONTINUE;
}

public plugin_cfg()
{
    g_EntMine = engfunc(EngFunc_AllocString,ENT_CLASS_NAME3);
    arrayset(g_havemine,0,sizeof(g_havemine));
    arrayset(g_deployed,0,sizeof(g_deployed));
    g_MaxPL = get_maxplayers();

    g_vault = nvault_open("lazer_ban");

    if(g_vault == INVALID_HANDLE)
    {
        set_fail_state("Bulunamayan nvault dosyasi lazer_ban Missing nvault file lazer_ban");
    }
}

public client_authorized(id, const authid[])
{
    g_int[iBanTime][id] = nvault_get(g_vault, fmt("%s-bantime", authid));
    if(g_int[iBanTime][id] > 0)
    {
        set_task(1.0, "CountdownBan", id + TASK_BAN);
    }
}

public Laser_TakeDamage(victim, inflictor, attacker, Float:f_Damage, bit_Damage)
{
    if(!g_LHEALTHMODE)
        return HAM_SUPERCEDE;

    if(g_LBEO)
    {
        new i_Owner
        i_Owner = pev(victim, LASERMINE_OWNER)

        if(CsTeams:pev(victim, LASERMINE_TEAM) == cs_get_user_team(attacker))
        if(i_Owner != attacker)
            return HAM_SUPERCEDE
        return PLUGIN_CONTINUE
    }
    return PLUGIN_CONTINUE
}

public delaycount(id)
{
    g_dcount[id] = floatround(get_gametime());
}

bool:CheckTime(id)
{
    g_nowtime = floatround(get_gametime()) - g_dcount[id];
    if(g_nowtime >= g_LDELAY)
        return true;
    return false;
}

public CreateLaserMine_Progress_b(id)
{
    CreateLaserMine_Progress(id);
    return PLUGIN_HANDLED;
}

public CreateLaserMine_Progress(id)
{
    if(!CreateCheck(id))
        return PLUGIN_HANDLED;
    g_settinglaser[id] = true;

    message_begin(MSG_ONE, g_msgBarTime, {0,0,0}, id);
    write_byte(1);
    write_byte(0);
    message_end();

    set_task(1.2, "Spawn", (TASK_PLANT + id));

    return PLUGIN_HANDLED;
}

public ReturnLaserMine_Progress(id)
{
    if(!ReturnCheck(id))
        return PLUGIN_HANDLED;
    g_settinglaser[id] = true;

    message_begin(MSG_ONE, g_msgBarTime, {0,0,0}, id);
    write_byte(1);
    write_byte(0);
    message_end();

    set_task(1.2, "ReturnMine", (TASK_RELEASE + id));

    return PLUGIN_HANDLED;
}

public StopCreateLaserMine(id)
{
    CancelProgress(id);
    return PLUGIN_HANDLED;
}

public StopReturnLaserMine(id)
{
    CancelProgress(id);
    return PLUGIN_HANDLED;
}

// Clears the progress bar + "setting" state. Used on key release AND on every failed plant/pickup,
// otherwise the player stays frozen (speed 1.0) with a stuck bar.
CancelProgress(id)
{
    DeleteTask(id);
    if(is_user_connected(id))
    {
        message_begin(MSG_ONE, g_msgBarTime, {0,0,0}, id);
        write_byte(0);
        write_byte(0);
        message_end();
    }
}

public ReturnMine(id)
{
    id -= TASK_RELEASE;

    if(!is_user_alive(id) || !IsOwnMineInReach(id))
    {
        CancelProgress(id);
        return;
    }

    new tgt, body;
    get_user_aiming(id, tgt, body);
    RemoveEntity(tgt);

    g_havemine[id]++;
    if(g_deployed[id] > 0) g_deployed[id]--;
    emit_sound(id, CHAN_ITEM, ENT_SOUND5, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
    ShowAmmo(id)
    DeleteTask(id);
}

// true when the player is aiming at one of his own lasermines within pickup distance
bool:IsOwnMineInReach(id)
{
    new tgt, body, Float:vo[3], Float:to[3];
    get_user_aiming(id, tgt, body);
    if(tgt <= g_MaxPL || !pev_valid(tgt)) return false;
    if(pev(tgt, pev_impulse) != LASERMINE_MAGIC) return false;
    if(pev(tgt, LASERMINE_OWNER) != id) return false;
    pev(id, pev_origin, vo);
    pev(tgt, pev_origin, to);
    return (get_distance_f(vo, to) <= 70.0);
}

// Finds where a mine can be planted: traces from the EYES along the crosshair.
// Rejects players and other lasermines. Returns the mine origin (vSpot) and the unit surface normal.
bool:GetPlantSpot(id, Float:vSpot[3], Float:vNormal[3])
{
    new Float:vStart[3], Float:vOfs[3], Float:vDir[3], Float:vEnd[3], Float:fFraction;

    pev(id, pev_origin, vStart);
    pev(id, pev_view_ofs, vOfs);
    xs_vec_add(vStart, vOfs, vStart);
    velocity_by_aim(id, PLANT_RANGE, vDir);
    xs_vec_add(vStart, vDir, vEnd);
    engfunc(EngFunc_TraceLine, vStart, vEnd, DONT_IGNORE_MONSTERS, id, 0);

    get_tr2(0, TR_flFraction, fFraction);
    if(fFraction >= 1.0)
        return false;

    new iHit = get_tr2(0, TR_pHit);
    if(iHit > 0 && pev_valid(iHit))
    {
        if(iHit <= g_MaxPL) return false;
        if(pev(iHit, pev_impulse) == LASERMINE_MAGIC) return false;
    }

    get_tr2(0, TR_vecEndPos, vEnd);
    get_tr2(0, TR_vecPlaneNormal, vNormal);
    xs_vec_mul_scalar(vNormal, 8.0, vDir);
    xs_vec_add(vEnd, vDir, vSpot);
    return true;
}

public Spawn(id)
{
    id -= TASK_PLANT;

    // The state can change during the 1.2s progress bar (ammo, death, limits) - re-validate.
    if(!is_user_alive(id) || g_havemine[id] <= 0 || g_deployed[id] >= g_LAMMO)
    {
        CancelProgress(id);
        return PLUGIN_HANDLED_MAIN;
    }

    // BUGFIX: validate the wall BEFORE allocating the entity. Previously a failed trace returned
    // after CreateNamedEntity() -> leaked an orphan entity every time and left the player frozen.
    new Float:vSpot[3], Float:vNormal[3];
    if(!GetPlantSpot(id, vSpot, vNormal))
    {
        client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_PLANTWALL")
        CancelProgress(id);
        return PLUGIN_HANDLED_MAIN;
    }

    new i_Ent = engfunc(EngFunc_CreateNamedEntity,g_EntMine);
    if(!pev_valid(i_Ent))
    {
        client_print(id, print_chat, "%s %L", MOD_TAG, id, "LM_CANTPLACE");
        CancelProgress(id);
        return PLUGIN_HANDLED_MAIN;
    }

    set_pev(i_Ent,pev_classname,ENT_CLASS_NAME);
    set_pev(i_Ent,pev_impulse,LASERMINE_MAGIC);
    engfunc(EngFunc_SetModel,i_Ent,ENT_MODELS);

    set_pev(i_Ent,pev_solid,SOLID_NOT);
    set_pev(i_Ent,pev_movetype,MOVETYPE_FLY);

    set_pev(i_Ent,pev_frame,0);
    set_pev(i_Ent,pev_body,3);
    set_pev(i_Ent,pev_sequence,TRIPMINE_WORLD);
    set_pev(i_Ent,pev_framerate,0);

    if(g_LHEALTHMODE)
    {
        set_pev(i_Ent,pev_takedamage,DAMAGE_YES);
        set_pev(i_Ent,pev_dmg,100.0);
        set_user_health(i_Ent,g_LHEALTH);
    }
    else
    {
        set_pev(i_Ent,pev_takedamage,DAMAGE_NO);
    }

    new Float:vEntAngles[3], Float:vBeamEnd[3], Float:vTracedBeamEnd[3];

    engfunc(EngFunc_SetSize, i_Ent, Float:{ -4.0, -4.0, -4.0 }, Float:{ 4.0, 4.0, 4.0 });
    engfunc(EngFunc_SetOrigin, i_Ent, vSpot);

    vector_to_angle(vNormal,vEntAngles);
    set_pev(i_Ent,pev_angles,vEntAngles);

    xs_vec_mul_scalar(vNormal, 8192.0, vBeamEnd);
    xs_vec_add(vSpot, vBeamEnd, vBeamEnd);
    engfunc(EngFunc_TraceLine, vSpot, vBeamEnd, IGNORE_MONSTERS, -1, 0);
    get_tr2(0, TR_vecEndPos, vTracedBeamEnd);

    set_pev(i_Ent, LASERMINE_OWNER, id);
    set_pev(i_Ent,LASERMINE_BEAMENDPOINT,vTracedBeamEnd);

#if defined BIOHAZARD
    set_pev(i_Ent, LASERMINE_TEAM, mod_is_zombie(id) ? 1 : 2);
#else
    set_pev(i_Ent, LASERMINE_TEAM, int:cs_get_user_team(id));
#endif

    new Float:fCurrTime = get_gametime();

    set_pev(i_Ent,LASERMINE_POWERUP, fCurrTime + 2.5);
    set_pev(i_Ent,LASERMINE_STEP,POWERUP_THINK);
    set_pev(i_Ent,pev_nextthink, fCurrTime + 0.2);

    PlaySound(i_Ent,POWERUP_SOUND);
    g_deployed[id]++;
    g_havemine[id]--;
    DeleteTask(id);
    ShowAmmo(id);
    return 1;
}

stock TeamDeployedCount(id)
{
    static i;
    static CsTeams:t;t = cs_get_user_team(id);
    static cnt;cnt=0;

    for(i = 1;i <= g_MaxPL;i++)
    {
        if(is_user_connected(i))
            if(t == cs_get_user_team(i))
                cnt += g_deployed[i];
    }

    return cnt;
}

bool:CheckCanTeam(id)
{
    new arg[5],CsTeam:num;
    get_pcvar_string(g_LCBT,arg,3);
    if(equali(arg,"Z"))
    {
        num = CsTeam:CS_TEAM_T;
    }
    else if(equali(arg,"H"))
    {
        num = CsTeam:CS_TEAM_CT;
    }
    else if(equali(arg,"ALL") || equali(arg,"HZ") || equali(arg,"ZH"))
    {
        num = CsTeam:CS_TEAM_UNASSIGNED;
    }
    else
    {
        num = CsTeam:CS_TEAM_UNASSIGNED;
    }
    if(num != CsTeam:CS_TEAM_UNASSIGNED && num != CsTeam:cs_get_user_team(id))
        return false;
    return true;
}

bool:CanCheck(id,mode)    
{
    if(!g_LENABLE)
    {
        client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_NOTACTIVE")
        return false;
    }
    if(g_LACCESS != 0)
        if(!(get_user_flags(id) & ADMIN_IMMUNITY))
        {
            client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_NOACCESS")
            return false;
        }
    if(!pev_user_alive(id)) return false;
    if(!CheckCanTeam(id))
    {
        client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_CBT")
        return false;
    }
    if(mode == 0)
    {
        if(g_havemine[id] <= 0)
        {
            client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_DONTHAVEMINE")
            return false;
        }
    }
    if(mode == 1)
    {
        if(g_LBUYMODE == 0)
        {
            client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_CANTBUY")
            return false;
        }
        if(g_havemine[id] >= g_LAMMO)
        {
            client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_HAVEMAX")
            return false;
        }
        if(mod_get_ammo(id) < g_LCOST)
        {
            client_print(id, print_chat, "%L %L%d %L", id, "CHATTAG",id, "STR_NOMONEY",g_LCOST,id, "STR_NEEDED")
            return false;
        }
    }
    if(!CheckTime(id))
    {
        client_print(id, print_chat, "%L %L %d %L", id, "CHATTAG",id, "STR_DELAY",g_LDELAY-g_nowtime,id, "STR_SECONDS")
        return false;
    }

    return true;
}

bool:ReturnCheck(id)
{
    if(!CanCheck(id,-1)) return false;
    if(g_havemine[id] + 1 > g_LAMMO) return false;
    return IsOwnMineInReach(id);
}

bool:CreateCheck(id)
{
    if(!CanCheck(id,0)) return false;

    if(!mod_round_started() && g_NOROUND)
    {
        client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_NOROUND")
        return false;
    }

    if(g_int[iBanTime][id] > 0)
    {
        client_print(id, print_chat, "%s %L", MOD_TAG, id, "LM_BANNED_SELF", g_int[iBanTime][id])
        return false;
    }

    if(mod_mode_blocked())
    {
        client_print_color(id, id, "^3%s ^4%L", MOD_TAG, id, "LM_MODE_BLOCKED");
        return false;
    }

    if(g_deployed[id] >= g_LAMMO)
    {
        client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_MAXDEPLOY")
        return false;
    }

    if(TeamDeployedCount(id) >= g_LTMAX)
    {
        client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_MANYPPL")
        return false;
    }

    new Float:vSpot[3], Float:vNormal[3];
    if(GetPlantSpot(id, vSpot, vNormal))
        return true;

    client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_PLANTWALL")
    DeleteTask(id);
    return false;
}

public ltm_Think(i_Ent)
{
    if(!g_LENABLE || i_Ent <= g_MaxPL || !pev_valid(i_Ent))
        return FMRES_IGNORED;
    if(pev(i_Ent, pev_impulse) != LASERMINE_MAGIC)
        return FMRES_IGNORED;
    new EntityName[32];

    static Float:fCurrTime;
    fCurrTime = get_gametime();

    switch(pev(i_Ent, LASERMINE_STEP))
    {
        case POWERUP_THINK :
        {
            new Float:fPowerupTime;
            pev(i_Ent, LASERMINE_POWERUP, fPowerupTime);

            if(fCurrTime > fPowerupTime)
            {
                set_pev(i_Ent, pev_solid, SOLID_BBOX);
                set_pev(i_Ent, LASERMINE_STEP, BEAMBREAK_THINK);

                PlaySound(i_Ent, ACTIVATE_SOUND);
            }

            if(g_LGLOW != 0)
            {
                if(g_LCLMODE == 0)
                {
                    switch (pev(i_Ent, LASERMINE_TEAM))
                    {
                        case 1: set_rendering(i_Ent, kRenderFxGlowShell, Red_Zomb, Green_Zomb, Blue_Zomb, kRenderNormal, 5);
                        case 2: set_rendering(i_Ent, kRenderFxGlowShell, Red_Hum, Green_Hum, Blue_Hum, kRenderNormal, 5);
                    }
                }
                else
                {
                    set_rendering(i_Ent, kRenderFxGlowShell, random_num(50, 200), random_num(50, 200), random_num(50, 200), kRenderNormal, 5);
                }
            }

            set_pev(i_Ent, pev_nextthink, fCurrTime + 0.1);
        }
        case BEAMBREAK_THINK :
        {
            static Float:vEnd[3],Float:vOrigin[3];
            pev(i_Ent, pev_origin, vOrigin);
            pev(i_Ent, LASERMINE_BEAMENDPOINT, vEnd);

            static iHit, Float:fFraction;
            engfunc(EngFunc_TraceLine, vOrigin, vEnd, DONT_IGNORE_MONSTERS, i_Ent, 0);

            get_tr2(0, TR_flFraction, fFraction);
            iHit = get_tr2(0, TR_pHit);

            if(fFraction < 1.0)
            {
                if(pev_valid(iHit))
                {
                    pev(iHit, pev_classname, EntityName, 31);
                    if(!equal(EntityName, ENT_CLASS_NAME) && !equal(EntityName, gSnarkClassName) && !equal(EntityName, barnacle_class) && !equal(EntityName, weapon_box))
                    {
                        set_pev(i_Ent, pev_enemy, iHit);

                        if(g_LMODE == MODE_LASERMINE)
                            CreateLaserDamage(i_Ent,iHit);
                        else
                            if(g_LFF || (pev(i_Ent,LASERMINE_TEAM) != (mod_is_zombie(iHit) ? 1 : 2)))
                                set_pev(i_Ent, LASERMINE_STEP, EXPLOSE_THINK);

                        if (!pev_valid(i_Ent))   
                            return FMRES_IGNORED;

                        set_pev(i_Ent, pev_nextthink, fCurrTime + random_float(0.1, 0.3));
                    }
                }
            }
            if(g_LDMGMODE!=0)
                if(pev(i_Ent,LASERMINE_HITING) != iHit)
                    set_pev(i_Ent,LASERMINE_HITING,iHit);

            if(pev_valid(i_Ent))
            {
                if(g_LHEALTHMODE)
                {
                    static Float:fHealth;
                    pev(i_Ent, pev_health, fHealth);

                    if(fHealth <= 0.0 || (pev(i_Ent,pev_flags) & FL_KILLME))
                    {
                        set_pev(i_Ent, LASERMINE_STEP, EXPLOSE_THINK);
                        set_pev(i_Ent, pev_nextthink, fCurrTime + random_float(0.1, 0.3));
                    }
                }

                static Float:fBeamthink;
                pev(i_Ent, LASERMINE_BEAMTHINK, fBeamthink);

                if(fBeamthink < fCurrTime && g_LVISIBLE)
                {
                    DrawLaser(i_Ent, vOrigin, vEnd);
                    set_pev(i_Ent, LASERMINE_BEAMTHINK, fCurrTime + 0.1);
                }
                set_pev(i_Ent, pev_nextthink, fCurrTime + 0.01);
            }
        }
        case EXPLOSE_THINK :
        {
            set_pev(i_Ent, pev_nextthink, 0.0);
            PlaySound(i_Ent, STOP_SOUND);
            new iOwner = pev(i_Ent,LASERMINE_OWNER);
            if(g_deployed[iOwner] > 0) g_deployed[iOwner]--;
            CreateExplosion(i_Ent);
            CreateDamage(i_Ent,g_LRDMG,g_LRADIUS)
            RemoveEntity(i_Ent);
        }
    }

    return FMRES_IGNORED;
}

public ltm_Touch(toucher, touched)
{
    if(touched <= g_MaxPL || !pev_valid(touched)) return FMRES_IGNORED;
    if(pev(touched, pev_impulse) != LASERMINE_MAGIC) return FMRES_IGNORED;
    if(!(1 <= toucher <= g_MaxPL) || !is_user_alive(toucher)) return FMRES_IGNORED;

    set_pev(touched, pev_solid, SOLID_NOT)
    if(!task_exists(touched))
        set_task(1.0, "solid_again", touched)

    return FMRES_IGNORED
}

public solid_again(i_Ent)
{
    if(!pev_valid(i_Ent)) return FMRES_IGNORED;

    if(pev(i_Ent, pev_impulse) != LASERMINE_MAGIC) return FMRES_IGNORED;

    set_pev(i_Ent, pev_solid, SOLID_BBOX);

    return FMRES_IGNORED;
}

PlaySound(i_Ent, i_SoundType)
{
    switch (i_SoundType)
    {
        case POWERUP_SOUND :
        {
            emit_sound(i_Ent, CHAN_VOICE, ENT_SOUND1, VOL_NORM, ATTN_NORM, 0, PITCH_NORM);
            emit_sound(i_Ent, CHAN_BODY , ENT_SOUND2, 0.2, ATTN_NORM, 0, PITCH_NORM);
        }
        case ACTIVATE_SOUND :
        {
            emit_sound(i_Ent, CHAN_VOICE, ENT_SOUND3, 0.5, ATTN_NORM, 1, 75);
        }
        case STOP_SOUND :
        {
            emit_sound(i_Ent, CHAN_BODY , ENT_SOUND2, 0.2, ATTN_NORM, SND_STOP, PITCH_NORM);
            emit_sound(i_Ent, CHAN_VOICE, ENT_SOUND3, 0.5, ATTN_NORM, SND_STOP, 75);
        }
    }
}

DrawLaser(i_Ent, const Float:v_Origin[3], const Float:v_EndOrigin[3])
{
    new tcolor[3];
    new teamid = pev(i_Ent, LASERMINE_TEAM);
    if(g_LCLMODE == 0)
    {
        switch(teamid){
            case 1:{
                tcolor[0] = Red_Zomb;
                tcolor[1] = Green_Zomb;
                tcolor[2] = Blue_Zomb;
            }
            case 2:{
                tcolor[0] = Red_Hum;
                tcolor[1] = Green_Hum;
                tcolor[2] = Blue_Hum;
            }
        }
    }else
    {
        tcolor[0] = random_num(50 , 200);
        tcolor[1] = random_num(50 , 200);
        tcolor[2] = random_num(50 , 200);
    }
    message_begin(MSG_BROADCAST,SVC_TEMPENTITY);
    write_byte(TE_BEAMPOINTS);
    engfunc(EngFunc_WriteCoord,v_Origin[0]);
    engfunc(EngFunc_WriteCoord,v_Origin[1]);
    engfunc(EngFunc_WriteCoord,v_Origin[2]);
    engfunc(EngFunc_WriteCoord,v_EndOrigin[0]); 
    engfunc(EngFunc_WriteCoord,v_EndOrigin[1]); 
    engfunc(EngFunc_WriteCoord,v_EndOrigin[2]); 
    write_short(beam);
    write_byte(0);
    write_byte(0);
    write_byte(1);    
    write_byte(5);   
    write_byte(0);   
    write_byte(tcolor[0]); 
    write_byte(tcolor[1]); 
    write_byte(tcolor[2]);
    write_byte(g_LCBRIGHT);
    write_byte(255);
    message_end();
}

CreateDamage(iCurrent,Float:DmgMAX,Float:Radius)
{
    new Float:vecSrc[3];
    pev(iCurrent, pev_origin, vecSrc);

    new AtkID =pev(iCurrent,LASERMINE_OWNER);
    new TeamID=pev(iCurrent,LASERMINE_TEAM);

    new ent = -1;
    new Float:tmpdmg = DmgMAX;

    new Float:kickback = 0.0;
    new Float:Tabsmin[3], Float:Tabsmax[3];
    new Float:vecSpot[3];
    new Float:Aabsmin[3], Float:Aabsmax[3];
    new Float:vecSee[3];
    new trRes;
    new Float:flFraction;
    new Float:vecEndPos[3];
    new Float:distance;
    new Float:origin[3], Float:vecPush[3];
    new Float:invlen;
    new Float:velocity[3];
    new iHitHP,iHitTeam;
    new Float:falloff;
    if(Radius > 0.0)
    {
        falloff = DmgMAX / Radius;
    } else {
        falloff = 1.0;
    }
    while((ent = engfunc(EngFunc_FindEntityInSphere, ent, vecSrc, Radius)) != 0)
    {
        if(!pev_valid(ent)) continue;
        if(!(pev(ent, pev_flags) & (FL_CLIENT | FL_FAKECLIENT | FL_MONSTER)))
        {
            continue;
        }
        if(!pev_user_alive(ent)) continue;
        kickback = 1.0;
        tmpdmg = DmgMAX;
        pev(ent, pev_absmin, Tabsmin);
        pev(ent, pev_absmax, Tabsmax);
        xs_vec_add(Tabsmin,Tabsmax,Tabsmin);
        xs_vec_mul_scalar(Tabsmin,0.5,vecSpot);
        pev(iCurrent, pev_absmin, Aabsmin);
        pev(iCurrent, pev_absmax, Aabsmax);
        xs_vec_add(Aabsmin,Aabsmax,Aabsmin);
        xs_vec_mul_scalar(Aabsmin,0.5,vecSee);
        engfunc(EngFunc_TraceLine, vecSee, vecSpot, 0, iCurrent, trRes);
        get_tr2(trRes, TR_flFraction, flFraction);
        if(flFraction >= 0.9 || get_tr2(trRes, TR_pHit) == ent)
        {
            get_tr2(trRes, TR_vecEndPos, vecEndPos);
            distance = get_distance_f(vecSrc, vecEndPos) * falloff;
            tmpdmg -= distance;
            if(tmpdmg < 0.0)
                tmpdmg = 0.0;
            if(kickback != 0.0)
            {
                xs_vec_sub(vecSpot,vecSee,origin);
                invlen = 1.0/get_distance_f(vecSpot, vecSee);

                xs_vec_mul_scalar(origin,invlen,vecPush);
                pev(ent, pev_velocity, velocity)
                xs_vec_mul_scalar(vecPush,tmpdmg,vecPush);
                xs_vec_mul_scalar(vecPush,kickback,vecPush);
                xs_vec_add(velocity,vecPush,velocity);
                if(tmpdmg < 60.0)
                {
                    xs_vec_mul_scalar(velocity,12.0,velocity);
                } else {
                    xs_vec_mul_scalar(velocity,4.0,velocity);
                }
                if(velocity[0] != 0.0 || velocity[1] != 0.0 || velocity[2] != 0.0)
                {
                    set_pev(ent, pev_velocity, velocity)
                }
            }

            iHitHP = pev_user_health(ent) - floatround(tmpdmg)
            iHitTeam = mod_is_zombie(ent) ? 1 : 2
            if(iHitHP <= 0)
            {
                if(iHitTeam != TeamID)
                {
                    mod_set_ammo(AtkID,mod_get_ammo(AtkID) + g_LFMONEY)
                    set_score(AtkID,ent,1,iHitHP)
                }else
                {
                    if(g_LFF)
                    {
                        mod_set_ammo(AtkID,mod_get_ammo(AtkID) - g_LFMONEY)
                        set_score(AtkID,ent,-1,iHitHP)
                    }
                }
            }else
            {
                if(iHitTeam != TeamID || g_LFF)
                {
                    set_user_health(ent, iHitHP)
                    engfunc(EngFunc_MessageBegin,MSG_ONE_UNRELIABLE,g_msgDamage,{0.0,0.0,0.0},ent);
                    write_byte(floatround(tmpdmg))
                    write_byte(floatround(tmpdmg))
                    write_long(DMG_BULLET)
                    engfunc(EngFunc_WriteCoord,vecSrc[0])
                    engfunc(EngFunc_WriteCoord,vecSrc[1])
                    engfunc(EngFunc_WriteCoord,vecSrc[2])
                    message_end()
                }
            }
        }
    }
    return
}

bool:pev_user_alive(ent)
{
    new deadflag = pev(ent,pev_deadflag);
    if(deadflag != DEAD_NO)
        return false;
    return true;
}

CreateExplosion(iCurrent)
{
    new Float:vOrigin[3];
    pev(iCurrent,pev_origin,vOrigin);

    message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
    write_byte(99);
    write_short(iCurrent);
    message_end();

    engfunc(EngFunc_MessageBegin, MSG_PVS, SVC_TEMPENTITY, vOrigin, 0);
    write_byte(TE_EXPLOSION);
    engfunc(EngFunc_WriteCoord,vOrigin[0]);
    engfunc(EngFunc_WriteCoord,vOrigin[1]);
    engfunc(EngFunc_WriteCoord,vOrigin[2]);
    write_short(boom);
    write_byte(30);
    write_byte(15);
    write_byte(0);
    message_end();
}

CreateLaserDamage(iCurrent,isHit)
{
    if(isHit < 0) return PLUGIN_CONTINUE
    switch(g_LDMGMODE)
    {
        case 1:
        {
            if(pev(iCurrent,LASERMINE_HITING) == isHit)
                return PLUGIN_CONTINUE
        }
        case 2:
        {
            if(pev(iCurrent,LASERMINE_HITING) == isHit)
            {
                static Float:cnt
                static now,htime;now = floatround(get_gametime())

                pev(iCurrent,LASERMINE_COUNT,cnt)
                htime = floatround(cnt)
                if(now - htime < g_LDSEC)
                {
                    return PLUGIN_CONTINUE;
                }else{
                    set_pev(iCurrent,LASERMINE_COUNT,get_gametime())
                }
            }else
            {
                set_pev(iCurrent,LASERMINE_COUNT,get_gametime())
            }
        }
    }

    new Float:vOrigin[3],Float:vEnd[3]
    pev(iCurrent,pev_origin,vOrigin)
    pev(iCurrent,pev_vuser1,vEnd)

    new teamid = pev(iCurrent, LASERMINE_TEAM)

    new szClassName[32]
    new Alive,God
    new iHitTeam,iHitHP,id
    new hitscore

    szClassName[0] = '^0'
    pev(isHit,pev_classname,szClassName,32)
    if((pev(isHit, pev_flags) & (FL_CLIENT | FL_FAKECLIENT | FL_MONSTER)))
    {
        Alive = pev_user_alive(isHit)
        God = get_user_godmode(isHit)
        if(!Alive || God) return PLUGIN_CONTINUE
        iHitTeam = mod_is_zombie(isHit) ? 1 : 2
        iHitHP = pev_user_health(isHit) - g_LDMG
        id = pev(iCurrent,LASERMINE_OWNER)
        if(iHitHP <= 0)
        {
            if(iHitTeam != teamid)
            {
                emit_sound(isHit, CHAN_WEAPON, ENT_SOUND4, 1.0, ATTN_NORM, 0, PITCH_NORM)
                hitscore = 1
                mod_set_ammo(id,mod_get_ammo(id) + g_LFMONEY)
                set_score(id,isHit,hitscore,iHitHP)
            }
            else
            {
                if(g_LFF)
                {
                    emit_sound(isHit, CHAN_WEAPON, ENT_SOUND4, 1.0, ATTN_NORM, 0, PITCH_NORM)
                    hitscore = -1
                    mod_set_ammo(id,mod_get_ammo(id) - g_LFMONEY)
                    set_score(id,isHit,hitscore,iHitHP)
                }
            }
        }
        else if(iHitTeam != teamid || g_LFF)
        {
            emit_sound(isHit, CHAN_WEAPON, ENT_SOUND4, 1.0, ATTN_NORM, 0, PITCH_NORM)
            set_user_health(isHit,iHitHP)
            set_pev(iCurrent,LASERMINE_HITING,isHit);
            engfunc(EngFunc_MessageBegin,MSG_ONE_UNRELIABLE,g_msgDamage,{0.0,0.0,0.0},isHit);
            write_byte(g_LDMG)
            write_byte(g_LDMG)
            write_long(DMG_BULLET)
            engfunc(EngFunc_WriteCoord,vOrigin[0])
            engfunc(EngFunc_WriteCoord,vOrigin[1])
            engfunc(EngFunc_WriteCoord,vOrigin[2])
            message_end()
        }
    }
    else if(equal(szClassName, ENT_CLASS_NAME3))
    {
        if(g_LHEALTHMODE)
        {
            new hl;
            hl = pev_user_health(isHit);
            set_user_health(isHit,hl-g_LDMG);
        }
    }
    return PLUGIN_CONTINUE
}

stock pev_user_health(id)
{
    new Float:health
    pev(id,pev_health,health)
    return floatround(health)
}

stock set_user_health(id,health)
{
    health > 0 ? set_pev(id, pev_health, float(health)) : dllfunc(DLLFunc_ClientKill, id);
}

stock get_user_godmode(index) {
    new Float:val
    pev(index, pev_takedamage, val)
    return (val == DAMAGE_NO)
}

stock set_user_frags(index, frags)
{
    set_pev(index, pev_frags, float(frags))
    return 1
}

stock pev_user_frags(index)
{
    new Float:frags;
    pev(index,pev_frags,frags);
    return floatround(frags);
}

set_score(id,target,hitscore,HP){
    new idfrags = pev_user_frags(id) + hitscore
    set_user_frags(id,idfrags)
    new tarfrags = pev_user_frags(target) + 1 
    set_user_frags(target,tarfrags)
    new idteam = mod_is_zombie(id) ? 1 : 2
    new iddeaths = cs_get_user_deaths(id)

    message_begin(MSG_ALL, g_msgDeathMsg, {0, 0, 0} ,0)
    write_byte(id)
    write_byte(target)
    write_byte(0)
    write_string(ENT_CLASS_NAME)
    message_end()

    message_begin(MSG_ALL, g_msgScoreInfo)
    write_byte(id)
    write_short(idfrags)
    write_short(iddeaths)
    write_short(0)
    write_short(idteam)
    message_end()

    set_msg_block(g_msgDeathMsg, BLOCK_ONCE)
    set_user_health(target, HP)
}

public BuyLasermine(id)
{
    if(!CanCheck(id,1)) return PLUGIN_CONTINUE

    mod_set_ammo(id,mod_get_ammo(id) - g_LCOST)
    g_havemine[id]++;

    client_print(id, print_chat, "%L %L", id, "CHATTAG",id, "STR_BOUGHT")

    emit_sound(id, CHAN_ITEM, ENT_SOUND5, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
    ShowAmmo(id)
    return PLUGIN_HANDLED
}

ShowAmmo(id)
{
    new ammo[51]
    new PlugStat[ 555 char ];
    formatex(PlugStat, charsmax(PlugStat), "%L", LANG_PLAYER, "STR_STATE")
    formatex(ammo, 50, "%s %i/%i",PlugStat, g_havemine[id],g_LAMMO)

    // Lasermine durumu / ammo yazisi sol altta sari renkte
    set_hudmessage(255, 255, 0, 0.02, 0.85, 0, 0.0, 2.0, 0.1, 0.1, 4);
    show_hudmessage(id, "%s", ammo);
}

public showInfo(id)
{
    client_print(id, print_chat, "%L", id, "STR_REF")
}

public say_lasermine(id){
    new said[32]
    read_argv(1,said,31);
    if(!g_LENABLE)
    {
        return PLUGIN_CONTINUE
    }
    if(equali(said,"/buy lasermine")||equali(said,"/lm")||equali(said,"buy_lasermine")){
        BuyLasermine(id)
    }else if(equali(said, "lasermine") || equali(said, "/lasermine")){
        const SIZE = 1400
        new msg[SIZE+1],len = 0;
        len += formatex(msg[len], SIZE - len, "<html><body>")
        len += formatex(msg[len], SIZE - len, "%L", id, "LM_MOTD_1")
        len += formatex(msg[len], SIZE - len, "%L", id, "LM_MOTD_2")
        len += formatex(msg[len], SIZE - len, "%L", id, "LM_MOTD_3")
        len += formatex(msg[len], SIZE - len, "%L", id, "LM_MOTD_4")
        len += formatex(msg[len], SIZE - len, "%L", id, "LM_MOTD_5")
        len += formatex(msg[len], SIZE - len, "%L", id, "LM_MOTD_6")
        len += formatex(msg[len], SIZE - len, "%L", id, "LM_MOTD_7")
        len += formatex(msg[len], SIZE - len, "</body></html>")
        show_motd(id, msg, fmt("%L", id, "LM_MOTD_TITLE"))
        return PLUGIN_CONTINUE
    }
    else if(containi(said, "laser") != -1) {
        showInfo(id)
        return PLUGIN_CONTINUE
    }
    return PLUGIN_CONTINUE
}

public standing(id)
{
    if(!g_settinglaser[id])
        return PLUGIN_CONTINUE

    set_pev(id, pev_maxspeed, 1.0)
    return PLUGIN_CONTINUE
}

public ltm_PostThink(id)
{
    if(!g_settinglaser[id] && plsetting[id]){
        resetspeed(id)
    }
    else if(g_settinglaser[id] && !plsetting[id]) {
        pev(id, pev_maxspeed,plspeed[id])
        set_pev(id, pev_maxspeed, 1.0)
    }
    plsetting[id] = g_settinglaser[id]
    return FMRES_IGNORED
}

public ltm_PreThink(id)
{
    if(g_LCMDMODE == 1 || g_settinglaser[id] || !pev_user_alive(id) || is_user_bot(id))
        return FMRES_IGNORED;

    if(pev(id, pev_button) & IN_USE && !(pev(id, pev_oldbuttons) & IN_USE))
        CreateLaserMine_Progress(id)
    return FMRES_IGNORED;
}

resetspeed(id)
{
    set_pev(id, pev_maxspeed, plspeed[id])
}

public client_putinserver(id){
    g_deployed[id] = 0;
    g_havemine[id] = 0;
    DeleteTask(id);
    
    client_cmd(id, "bind v +setlaser");
    client_cmd(id, "bind b +dellaser");
    
    return PLUGIN_CONTINUE
}

public client_disconnected(id){
    if(!g_LENABLE)
        return PLUGIN_CONTINUE
    DeleteTask(id);
    RemoveAllTripmines(id);

    remove_task(id + TASK_BAN);
    savevault(id);
    g_int[iBanTime][id] = 0;
    g_int[iPickPlayerr][id] = 0;
    return PLUGIN_CONTINUE
}

public newround(id)
{
    if(!g_LENABLE)
        return PLUGIN_CONTINUE
    pev(id, pev_maxspeed,plspeed[id])
    DeleteTask(id);
    RemoveAllTripmines(id);
    delaycount(id);
    SetStartAmmo(id);
    return PLUGIN_CONTINUE
}

RoundEndCleanup()
{
    if(!g_LENABLE)
        return;

    new players[32], pnum, id;
    get_players(players, pnum);

    for(new i = 0; i < pnum; i++)
    {
        id = players[i]
        RemoveAllTripmines(id);
        DeleteTask(id);
    }
}

#if defined BIOHAZARD

public logevent_round_end()
{
    RoundEndCleanup();
}

public event_infect(victim, attacker)
{
    RemoveAllTripmines(victim);
    SetStartAmmo(victim);
}

#else

public zp_round_ended(zp_team)
{
    RoundEndCleanup();
    return PLUGIN_CONTINUE
}

public zp_user_infected_post(id, infector, nemesis)
{
    RemoveAllTripmines(id);
    SetStartAmmo(id);
}

public zp_user_humanized_post(id, survivor)
{
    RemoveAllTripmines(id);
    SetStartAmmo(id);
}

#endif

public admin_lazer_sil(id,level)
{
    if(~get_user_flags(id) & ADMIN_RESERVATION) return PLUGIN_HANDLED
    
    new argument[32]
    read_argv(1,argument,31)

    new silinen = cmd_target(id,argument,CMDTARGET_ALLOW_SELF)

    if(!silinen) return PLUGIN_HANDLED
    if(is_user_bot(silinen)) return PLUGIN_HANDLED

    if(g_havemine[silinen] == g_LSTAMMO && is_user_alive(silinen))
    {
        client_print(id, print_chat, "%s %L", MOD_TAG, id, "LM_NOMINE")
        return PLUGIN_HANDLED
    }

    RemoveAllTripmines(silinen);
    SetStartAmmo(silinen);

    new names[2][32]
    get_user_name(id, names[0], 31)
    get_user_name(silinen, names[1], 31)

    client_print(0, print_chat, "%s %L", MOD_TAG, LANG_PLAYER, "LM_ADMIN_REMOVED", names[0], names[1])
    return PLUGIN_CONTINUE
}

public clcmd_lazersilmenu(id)
{
    if(~get_user_flags(id) & ADMIN_RESERVATION)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOPERM");
        return PLUGIN_HANDLED;
    }
    new bestm = menu_create(fmt("\r%s \w| \y%L", MOD_TAG, id, "LM_MENU_DEL"), "clcmd_lazersilmenu_");

    for(new i = 1; i <= MaxClients; i++)
    {
        if(!is_user_connected(i) || is_user_bot(i) || get_user_flags(i) & ADMIN_IMMUNITY){
            continue;
        }
        menu_additem(bestm, fmt("%n", i), fmt("%i", i));
    }
    menu_setprop(bestm, MPROP_EXITNAME, fmt("\r%L", id, "LM_EXIT"));
    menu_display(id, bestm);
    return PLUGIN_HANDLED;
}

public clcmd_lazersilmenu_(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }
    new data[6], key;
    menu_item_getinfo(menu, item, _, data, charsmax(data));
    key = str_to_num(data);

    if(is_user_alive(key))
    {
        if(g_havemine[key] == g_LSTAMMO)
        {
            client_print(id, print_chat, "%s %L", MOD_TAG, id, "LM_NOMINE")
            return PLUGIN_HANDLED
        }

        RemoveAllTripmines(key);
        SetStartAmmo(key);

        new names[2][32]
        get_user_name(id, names[0], 31)
        get_user_name(key, names[1], 31)

        client_print(0, print_chat, "%s %L", MOD_TAG, LANG_PLAYER, "LM_ADMIN_REMOVED", names[0], names[1])
    }

    menu_destroy(menu);
    return PLUGIN_HANDLED;
}

public DeathEvent(){
    if(!g_LENABLE)
        return PLUGIN_CONTINUE

    new id = read_data(2)
    if(is_user_connected(id)) DeleteTask(id);
    return PLUGIN_CONTINUE
}

public RemoveAllTripmines(i_Owner)
{
    new iEnt = g_MaxPL + 1;
    new clsname[32];
    while((iEnt = engfunc(EngFunc_FindEntityByString, iEnt, "classname", ENT_CLASS_NAME)))
    {
        if(i_Owner)
        {
            if(pev(iEnt, LASERMINE_OWNER) != i_Owner)
                continue;
            clsname[0] = '^0'
            pev(iEnt, pev_classname, clsname, sizeof(clsname)-1);
            if(equali(clsname, ENT_CLASS_NAME))
            {
                PlaySound(iEnt, STOP_SOUND);
                RemoveEntity(iEnt);
            }
        }
        else
            set_pev(iEnt, pev_flags, FL_KILLME);
    }
    g_deployed[i_Owner]=0;
}

SetStartAmmo(id)
{
    new stammo = g_LSTAMMO;
    if(stammo <= 0) return PLUGIN_CONTINUE;
    g_havemine[id] = (g_havemine[id] <= stammo) ? stammo : g_havemine[id];
    return PLUGIN_CONTINUE;
}

public CutDeploy_onDamage(id)
{
    if(get_user_health(id) < 1)
        DeleteTask(id);
}

DeleteTask(id)
{
    if(task_exists((TASK_PLANT + id)))
    {
        remove_task((TASK_PLANT + id))
    }
    if(task_exists((TASK_RELEASE + id)))
    {
        remove_task((TASK_RELEASE + id))
    }
    g_settinglaser[id] = false
    return PLUGIN_CONTINUE;
}

stock set_rendering(entity, fx = kRenderFxNone, r = 255, g = 255, b = 255, render = kRenderNormal, amount = 16)
{
    static Float:RenderColor[3];
    RenderColor[0] = float(r);
    RenderColor[1] = float(g);
    RenderColor[2] = float(b);

    set_pev(entity, pev_renderfx, fx);
    set_pev(entity, pev_rendercolor, RenderColor);
    set_pev(entity, pev_rendermode, render);
    set_pev(entity, pev_renderamt, float(amount));

    return 1
}

get_offset_value(id, type)
{
    new key = -1;
    switch(type)
    {
        case OFFSET_TEAM: key = OFFSET_TEAM;
        case OFFSET_MONEY: key = OFFSET_MONEY;
        case OFFSET_DEATH: key = OFFSET_DEATH;
    }
    if(key != -1)
    {
        return get_pdata_int(id, key);
    }
    return -1;
}

public fw_TraceLine( Float:fStart[3] , Float:fEnd[3] , Conditions , id , iTrace )
{
  // Post-hook of FM_TraceLine = fired for every trace on the server: bail out as early as possible.
  if(!(1 <= id <= g_MaxPL))
    return FMRES_IGNORED;

  static ent, szPlayerName[32], playerid, Float: fHealth;
  ent = get_tr2(iTrace, TR_pHit);

  if(ent <= g_MaxPL || !pev_valid(ent) || pev(ent, pev_impulse) != LASERMINE_MAGIC)
    return FMRES_IGNORED;

  if(!is_user_alive(id))
    return FMRES_IGNORED;

  playerid = pev(ent, LASERMINE_OWNER)
  if(is_user_connected(playerid))
    get_user_name(playerid, szPlayerName, 31)
  else
    copy(szPlayerName, 31, "-")

  if(pev(ent, LASERMINE_TEAM) == 1)
    set_hudmessage(255, 0, 0, -1.0, 0.60, 0, 0.1, 0.1, 0.1, 0.1);
  else
    set_hudmessage(0, 120, 255, -1.0, 0.60, 0, 0.1, 0.1, 0.1, 0.1);

  if(g_LHEALTHMODE)
  {
    static iMaxHp, Float:fPercent;
    pev(ent, pev_health, fHealth)
    iMaxHp = g_LHEALTH;
    fPercent = (iMaxHp > 0) ? (fHealth * 100.0 / float(iMaxHp)) : 0.0;

    show_hudmessage(id, "%L^n%L", id, "LM_OWNER", szPlayerName, id, "LM_LASERHP", fPercent);
  }
  else
  {
    show_hudmessage(id, "%L", id, "LM_OWNER", szPlayerName);
  }

  return FMRES_IGNORED;
}

public clcmd_lazerban(const id)
{
    if(~get_user_flags(id) & ADMIN_BAN)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOPERM");
        return PLUGIN_HANDLED;
    }
    new szArg[32], iArg[10];
    read_argv(1, szArg, charsmax(szArg));
    read_argv(2, iArg, charsmax(iArg));

    new iTime, pPlayer;
    iTime = str_to_num(iArg);
    pPlayer = find_player("bl", szArg);

    if(szArg[0] == EOS)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NONAME");
        return PLUGIN_HANDLED;
    }
    else if(iArg[0] == EOS)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOTIME");
        return PLUGIN_HANDLED;
    }

    BanThePlayer(id, pPlayer, iTime);
    return PLUGIN_HANDLED;
}

public clcmd_lazerunban(const id)
{
    if(~get_user_flags(id) & ADMIN_BAN)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOPERM");
        return PLUGIN_HANDLED;
    }
    new szArg[32];
    read_argv(1, szArg, charsmax(szArg));

    new pPlayer;
    pPlayer = find_player("bl", szArg);

    if(szArg[0] == EOS)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NONAME");
        return PLUGIN_HANDLED;
    }
    if(g_int[iBanTime][pPlayer] > 0)
    {
        remove_task(pPlayer + TASK_BAN);
        g_int[iBanTime][pPlayer] = 0;
        { 
            new szA[32], szB[32]; 
            get_user_name(id, szA, 31); 
            get_user_name(pPlayer, szB, 31);
            client_print_color(0, 0, "^3%s ^1%L", MOD_TAG, LANG_PLAYER, "LM_UNBAN_DONE", szA, szB); 
        }
        return PLUGIN_HANDLED;
    }
    else
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOBAN");
        return PLUGIN_HANDLED;
    }
}

public BanThePlayer(const id, const pPlayer, iTime)
{
    if(BanTermsOfUse(id, pPlayer, true, true, true))
    {
        return PLUGIN_HANDLED;
    }
    else if(!(iTime > 0))
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_TIME_GT0");
        return PLUGIN_HANDLED;
    }
    else
    {
        g_int[iBanTime][pPlayer] = iTime;
        set_task(1.0, "CountdownBan", pPlayer + TASK_BAN);
        { 
            new szA[32], szB[32]; 
            get_user_name(id, szA, 31); 
            get_user_name(pPlayer, szB, 31);
            client_print_color(0, 0, "^3%s ^1%L", MOD_TAG, LANG_PLAYER, "LM_BAN_SET", szA, szB, iTime); 
        }
        return PLUGIN_HANDLED;
    }
}

bool:BanTermsOfUse(const id, const pPlayer, bool:blFlags, bool:blPlayer, bool:blOnBan)
{
    if(blPlayer && !pPlayer)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOTFOUND");
        return true;
    }
    if(blFlags && get_user_flags(pPlayer) & ADMIN_IMMUNITY)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_IMMUNE");
        return true;
    }
    if(blOnBan && g_int[iBanTime][pPlayer] > 0)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_ALREADY");
        return true;
    }
    return false;
}

public CountdownBan(Taskid)
{
    new id;
    id = Taskid - TASK_BAN;

    if(g_int[iBanTime][id] > 0)
    {
        g_int[iBanTime][id]--;
        set_task(1.0, "CountdownBan", id + TASK_BAN);
    }
    else 
    {
        g_int[iBanTime][id] = 0;
        remove_task(id + TASK_BAN);
        { 
            new szA[32]; 
            get_user_name(id, szA, 31);
            client_print_color(0, 0, "^3%s ^1%L", MOD_TAG, LANG_PLAYER, "LM_BAN_ENDED", szA); 
        }
    }
}

public savevault(id)
{
    new authid[MAX_AUTHID_LENGTH];
    get_user_authid(id, authid, charsmax(authid));

    nvault_pset(g_vault, fmt("%s-bantime", authid), fmt("%i", g_int[iBanTime][id]));
}

public clcmd_lazerbanmenu(id)
{
    if(~get_user_flags(id) & ADMIN_BAN)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOPERM");
        return PLUGIN_HANDLED;
    }
    new bestm = menu_create(fmt("\r%s \w| \y%L", MOD_TAG, id, "LM_MENU_BAN"), "clcmd_lazerbanmenu_");

    for(new i = 1; i <= MaxClients; i++)
    {
        if(!is_user_connected(i) || is_user_bot(i) || get_user_flags(i) & ADMIN_IMMUNITY){
            continue;
        }
        menu_additem(bestm, fmt("%n", i), fmt("%i", i));
    }
    menu_setprop(bestm, MPROP_EXITNAME, fmt("\r%L", id, "LM_EXIT"));
    menu_display(id, bestm);
    return PLUGIN_HANDLED;
}

public clcmd_lazerbanmenu_(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }
    new data[6], key;
    menu_item_getinfo(menu, item, _, data, charsmax(data));
    key = str_to_num(data);

    g_int[iPickPlayerr][id] = key;
    client_cmd(id, "messagemode SureBelirlee");

    menu_destroy(menu);
    return PLUGIN_HANDLED;
}

public clcmd_SureBelirle(id)
{
    if(~get_user_flags(id) & ADMIN_BAN)
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOPERM");
        return PLUGIN_HANDLED;
    }
    new szArg[32];
    read_args(szArg, charsmax(szArg));
    remove_quotes(szArg);

    if(!g_int[iPickPlayerr][id])
    {
        client_print_color(id, id, "^4%s ^3%L", MOD_TAG, id, "LM_NOPICK");
        return PLUGIN_HANDLED;
    }
    new iTime = str_to_num(szArg);
    BanThePlayer(id, g_int[iPickPlayerr][id], iTime);
    return PLUGIN_HANDLED;
}