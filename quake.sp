#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smlib>
#include <tf2_stocks>

#pragma semicolon 1

#define JUMP_SPEED 300.0
#define AIR_CAP 30.0
#define FRAMETIME GetTickInterval()
// #define FRAMETIME 0.015 // 66.666666
#define PI 3.14159
#define MAX_STEP_HEIGHT 18 // https://developer.valvesoftware.com/wiki/Team_Fortress_2_Mapper's_Reference#Other_Info
#define DEBUG
// #define SKIP_FRICITON

// TODO: autohop duckjump, disable for spectators, version cvar, test speedap

// Variables {{{
new Handle:cvarEnabled          = INVALID_HANDLE;
new Handle:cvarAutohop          = INVALID_HANDLE;
new Handle:cvarSpeedo           = INVALID_HANDLE;
new Handle:cvarMaxspeed         = INVALID_HANDLE;
new Handle:cvarDuckJump         = INVALID_HANDLE;
new Handle:cvarFriction         = INVALID_HANDLE;
new Handle:cvarStopspeed        = INVALID_HANDLE;
new Handle:cvarAccelerate       = INVALID_HANDLE;
new Handle:cvarAirAccelerate    = INVALID_HANDLE;

// Global settings
new bool:enabled = true;
new bool:defaultAutohop = true;
new bool:defaultSpeedo = false;
new bool:duckjump = true;
new Float:speedcap = -1.0;
new Float:sv_friction = 4.0;
new Float:sv_stopspeed = 100.0;
new Float:sv_accelerate = 10.0;
new Float:sv_airaccelerate = 10.0;

// Player data
// Arrays are 1 bigger than MAXPLAYERS for the convenience of not having to
// write client - 1 every time when using a client id as index.
new Float:customMaxspeed[MAXPLAYERS + 1];
new Float:realMaxSpeeds [MAXPLAYERS + 1];
new Float:tmpvel        [MAXPLAYERS + 1];
new bool:autohop        [MAXPLAYERS + 1];
new bool:showSpeed      [MAXPLAYERS + 1];
new bool:inair          [MAXPLAYERS + 1];
new bool:landframe      [MAXPLAYERS + 1];
new bool:jumpPressed    [MAXPLAYERS + 1];
// new playerButtons       [MAXPLAYERS + 1];

#if defined DEBUG
new Float:debugSpeed;
new Float:debugVel[3];
new Float:debugProj;
new Float:debugWishdir[2];
new Float:debugAcc;
new Float:debugFrictionDrop;
new Float:debugEyeAngle;
new debugAngle;
#endif

public Plugin:myinfo = {
    name            = "Quake Movement",
    author          = "mphe",
    description     = "Quake/HL1 like movement",
    version         = "1.0.0",
    url             = "http://www.sourcemod.net"
};
// }}}

// Commands {{{
public Action:toggleAutohop(client, args)
{
    autohop[client] = !autohop[client];
    if (autohop[client])
        ReplyToCommand(client, "[QM] Autohopping enabled");
    else
        ReplyToCommand(client, "[QM] Autohopping disabled");
    return Plugin_Handled;
}

public Action:toggleSpeedo(client, args)
{
    showSpeed[client] = !showSpeed[client];
    PrintCenterText(client, "");
    return Plugin_Handled;
}
// }}}

// Convar changed hooks {{{
public ChangeEnabled(Handle:convar, const String:oldValue[], const String:newValue[])
{
    enabled = GetConVarBool(convar);
}

public ChangeSpeedo(Handle:convar, const String:oldValue[], const String:newValue[])
{
    defaultSpeedo = GetConVarBool(convar);
}

public ChangeDuckJump(Handle:convar, const String:oldValue[], const String:newValue[])
{
    duckjump = GetConVarBool(convar);
}

public ChangeAutohop(Handle:convar, const String:oldValue[], const String:newValue[])
{
    defaultAutohop = GetConVarBool(convar);
}

public ChangeMaxspeed(Handle:convar, const String:oldValue[], const String:newValue[])
{
    speedcap = GetConVarFloat(convar);
}

public ChangeFriction(Handle:convar, const String:oldValue[], const String:newValue[])
{
    sv_friction = GetConVarFloat(convar);
}

public ChangeStopspeed(Handle:convar, const String:oldValue[], const String:newValue[])
{
    sv_stopspeed = GetConVarFloat(convar);
}

public ChangeAccelerate(Handle:convar, const String:oldValue[], const String:newValue[])
{
    sv_accelerate = GetConVarFloat(convar);
}

public ChangeAirAccelerate(Handle:convar, const String:oldValue[], const String:newValue[])
{
    sv_airaccelerate = GetConVarFloat(convar);
}
// }}}

// Events {{{
public OnPluginStart()
{
    RegConsoleCmd("sm_speed", toggleSpeedo, "Toggle speedometer on/off");
    RegConsoleCmd("sm_togglehop", toggleAutohop, "Toggle autohopping on/off");

    cvarEnabled  = CreateConVar("qm_enabled",     "1", "Enable/Disable Quake movement.");
    cvarAutohop  = CreateConVar("qm_autohop",     "1", "Automatically jump while holding jump.");
    cvarSpeedo   = CreateConVar("qm_speedo",      "0", "Show speedometer.");
    cvarDuckJump = CreateConVar("qm_duckjump",    "1", "Allow jumping while being ducked.");
    cvarMaxspeed = CreateConVar("qm_maxspeed", "-1.0", "The maximum speed players can reach.");

    cvarFriction = FindConVar("sv_friction");
    cvarStopspeed = FindConVar("sv_stopspeed");
    cvarAccelerate = FindConVar("sv_accelerate");
    cvarAirAccelerate = FindConVar("sv_airaccelerate");

    sv_friction = GetConVarFloat(cvarFriction);
    sv_stopspeed = GetConVarFloat(cvarStopspeed);
    sv_accelerate = GetConVarFloat(cvarAccelerate);
    sv_airaccelerate = GetConVarFloat(cvarAirAccelerate);

    HookConVarChange(cvarEnabled, ChangeEnabled);
    HookConVarChange(cvarAutohop, ChangeAutohop);
    HookConVarChange(cvarSpeedo, ChangeSpeedo);
    HookConVarChange(cvarDuckJump, ChangeDuckJump);
    HookConVarChange(cvarMaxspeed, ChangeMaxspeed);
    HookConVarChange(cvarFriction, ChangeFriction);
    HookConVarChange(cvarStopspeed, ChangeStopspeed);
    HookConVarChange(cvarAccelerate, ChangeAccelerate);
    HookConVarChange(cvarAirAccelerate, ChangeAirAccelerate);

    for (new i = 1; i <= MaxClients; i++)
    {
        if (Client_IsValid(i) && IsClientInGame(i))
        {
            SetupClient(i);
            HookClient(i);
        }
    }
}

public OnClientPutInServer(client)
{
    HookClient(client);
    SetupClient(client);
}

public OnPreThink(client)
{
    if (!enabled || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;
    DoStuffPre(client);
}

public OnPostThink(client)
{
    if (!enabled || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;
    DoStuffPost(client);
}
// }}}

public DoStuffPost(client)
{
    // Catch weapon related speed boosts (they don't appear in PreThink)
    if (GetMaxSpeed(client) != customMaxspeed[client])
        realMaxSpeeds[client] = GetMaxSpeed(client);

    // Restore speed if above 520
    if (!inair[client] && tmpvel[client] > 520.0)
    {
        decl Float:vel[3];
        GetVelocity(client, vel);
        new Float:speed = GetAbsVec(vel);
        for (new i = 0; i < 2; i++)
            vel[i] *= tmpvel[client] / speed;
        DoFriction(client, vel);
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
    }

    ShowSpeedo(client);

    // Reset max speed
    SetMaxSpeed(client, realMaxSpeeds[client]);
}

public DoStuffPre(client)
{
    realMaxSpeeds[client] = GetMaxSpeed(client);

    decl Float:vel[3];
    GetVelocity(client, vel);
    new Float:speed = GetAbsVec(vel);
    tmpvel[client] = speed;

#if defined DEBUG
    decl Float:dir[3];
    GetClientEyeAngles(client, dir);
    debugEyeAngle = ConvertAngle(dir[1]);
    debugAngle = RoundFloat(FloatAbs(dir[1])) % 45;
    if (debugAngle > 30)
        debugAngle = 45 - debugAngle;
#endif

    new buttons = GetClientButtons(client);

    // {{{
    CheckGround(client);

    if (!inair[client])
    {
        if (landframe[client])
        {
            // Pressing jump while landing?
            if (autohop[client] && buttons & IN_JUMP)
            {
                vel[2] = JUMP_SPEED;
                TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
            }
        }

        // Jumping while crouching
        if (duckjump && !jumpPressed[client] && buttons & IN_JUMP && buttons & IN_DUCK)
        {
            vel[2] = JUMP_SPEED;
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
        }
    }

    // Double negate to prevent tag mismatch warning
    jumpPressed[client] = !!(buttons & IN_JUMP);
    // }}}

    // Movement prediction {{{
    // if (inair[client])
    // {
    //     // SetMaxSpeed(client, 10000.0); // Breaks cloak and dagger
    //     return;
    // }

    new Float:maxspeed = realMaxSpeeds[client];
    new Float:drop = GetFrictionDrop(client, speed);
    new Float:acc = GetAcceleration(client, maxspeed);
    new Float:maxnewspeed = speed - drop + acc;

    // No need to intervene if the maximum gainable speed is still below maxspeed
    if (maxnewspeed <= maxspeed)
        return;

    decl Float:wishdir[3];
    GetWishdir(client, buttons, wishdir);

    if (speed == 0.0) // || wishdir[0] == 0.0 || wishdir[1] == 0.0)
        return;

    if (wishdir[0] != 0.0 || wishdir[1] != 0.0)
    {
        DoFriction(client, vel);
        Accelerate(client, vel, wishdir, inair[client]);
    }

    speed = GetAbsVec(vel);

    if (speedcap < 0.0)
        maxspeed = speed;
    else
        maxspeed = speed < speedcap ? speed : speedcap;

    if (FloatAbs(maxspeed - realMaxSpeeds[client]) > 0.1)
    {
        customMaxspeed[client] = maxspeed;
        SetMaxSpeed(client, maxspeed);
        // PrintToServer("SetMaxSpeed: %f", maxspeed);
    }

#if defined DEBUG
    debugSpeed = speed;
    for (new i = 0; i < 3; i++)
        debugVel[i] = vel[i];
    for (new i = 0; i < 2; i++)
        debugWishdir[i] = wishdir[i];
#endif
    // }}}
}

DoFriction(client, Float:vel[3])
{
    if (inair[client] || landframe[client])
        return;

    new Float:speed = GetAbsVec(vel);

    if (speed > 0.001)
    {
        new Float:drop = GetFrictionDrop(client, speed);
        new Float:scale = (speed - drop) / speed;
        if (scale < 0.0)
            scale = 0.0;
        for (new i = 0; i < 2; i++)
            vel[i] *= scale;

#if defined DEBUG
        debugFrictionDrop = drop;
#endif
    }
}

ShowSpeedo(client)
{
    if (showSpeed[client])
    {
        decl Float:vel[3];
        GetVelocity(client, vel);
        new Float:abs = GetAbsVec(vel);
#if defined DEBUG
        PrintCenterText(client, "realvel: %f\n%f;%f\npredicted: %f\n%f\n%f\nmaxspeed: %f, %f\nproj: %f\nwishdir: (%f;%f)\nacc: %f\ndrop: %f %f\neyeangle: %f\nangle: %i",
                abs, vel[0], vel[1],
                debugSpeed, debugVel[0], debugVel[1],
                realMaxSpeeds[client], GetMaxSpeed(client),
                debugProj,
                debugWishdir[0], debugWishdir[1],
                debugAcc,
                GetFriction(client), debugFrictionDrop,
                debugEyeAngle,
                debugAngle
                );
#else
        PrintCenterText(client, "%f", abs);
#endif
    }
}

// Calculates the acceleration between the last and the current frame, adds
// it together the "Quake way" and stores it in newvel.
// newvel: The (untouched) velocity vector
// wishdir: The acceleration direction (normalized)
Accelerate(client, Float:vel[3], const Float:wishdir[3], bool:air)
{
    new Float:maxspeed = realMaxSpeeds[client];

    if (air && maxspeed > AIR_CAP)
        maxspeed = AIR_CAP;

    new Float:currentspeed = DotProduct(vel, wishdir);
    new Float:addspeed = maxspeed - currentspeed;

    if (addspeed < 0)
        return;

    new Float:acc = GetAcceleration(client, realMaxSpeeds[client], air);

    if (acc > addspeed)
        acc = addspeed;

    for (new i = 0; i < 2; i++)
        vel[i] += wishdir[i] * acc;

#if defined DEBUG
    debugProj = currentspeed;
    debugAcc = acc;
#endif
}

CheckGround(client)
{
    if (GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") == -1)
    {
        inair[client] = true;
    }
    else
    {
        landframe[client] = false;
        if (inair[client])
        {
            inair[client] = false;
            landframe[client] = true;
        }
    }
}

// Helper functions {{{

// Caluclate the friction to subtract for a certain speed.
Float:GetFrictionDrop(client, Float:speed)
{
    new Float:friction = sv_friction * GetFriction(client);
    new Float:control = (speed < sv_stopspeed) ? sv_stopspeed : speed;
    return (control * friction * FRAMETIME);
}

Float:GetAcceleration(client, Float:maxspeed, bool:air = false)
{
    return (air ? sv_airaccelerate : sv_accelerate) * FRAMETIME * maxspeed * GetFriction(client);
}

Float:ConvertAngle(Float:angle)
{
    return angle < 0.0 ? 360.0 + angle : angle;
}

// Fills the fwd and right vector with a unit vector pointing in the
// direction the client is looking and the right of it.
// fwd and right must be 3D vectors, although their z value is always zero.
GetViewAngle(client, Float:fwd[3], Float:right[3])
{
    GetClientEyeAngles(client, fwd);
    fwd[0] = Cosine(DegToRad(fwd[1]));
    fwd[1] = Sine(DegToRad(fwd[1]));
    fwd[2] = 0.0;
    right[0] = fwd[1];
    right[1] = -fwd[0];
    right[2] = 0.0;
}

// Fills wishdir with a normalized vector pointing in the direction the
// player wants to move in.
GetWishdir(client, buttons, Float:wishdir[3])
{
    decl Float:fwd[3], Float:right[3];
    GetViewAngle(client, fwd, right);

    wishdir[0] = wishdir[1] = wishdir[2] = 0.0;

    if (buttons & IN_FORWARD || buttons & IN_BACK || buttons & IN_MOVERIGHT || buttons & IN_MOVELEFT)
    {
        if (buttons & IN_FORWARD)
            AddVectors(wishdir, fwd, wishdir);
        if (buttons & IN_BACK)
            SubtractVectors(wishdir, fwd, wishdir);
        if (buttons & IN_MOVERIGHT)
            AddVectors(wishdir, right, wishdir);
        if (buttons & IN_MOVELEFT)
            SubtractVectors(wishdir, right, wishdir);

        NormalizeVector(wishdir, wishdir);
    }
}

// Setup, Variables, Misc, ... {{{
HookClient(client)
{
    SDKHook(client, SDKHook_PreThink, OnPreThink);
    SDKHook(client, SDKHook_PostThink, OnPostThink);
}

SetupClient(client)
{
    autohop[client] = defaultAutohop;
    showSpeed[client] = defaultSpeedo;
}

GetVelocity(client, Float:vel[3])
{
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
}

Float:GetFriction(client)
{
    // Not sure if this will ever be different than 1.0
#if defined SKIP_FRICITON
    return 1.0;
#else
    return GetEntPropFloat(client, Prop_Data, "m_flFriction");
#endif
}

Float:GetMaxSpeed(client)
{
    return GetEntPropFloat(client, Prop_Data, "m_flMaxspeed");
}

Float:SetMaxSpeed(client, Float:speed)
{
    SetEntPropFloat(client, Prop_Data, "m_flMaxspeed", speed);
}

public bool:TR_FilterSelf(ent, mask, any:data)
{
    return ent != data;
}
// }}}

// 2D Vector functions {{{
Float:GetAngleBetween(const Float:a[], const Float:b[])
{
    return ArcCosine(DotProduct(a, b) / (GetAbsVec(a) * GetAbsVec(b))) * 180 / PI;
}

Float:DotProduct(const Float:a[], const Float:b[])
{
    return a[0] * b[0] + a[1] * b[1];
}

// Calculates the unit vector for a and stores it in b.
GetUnitVec(const Float:a[], Float:b[])
{
    new Float:len = GetAbsVec(a);
    for (new i = 0; i < 2; i++)
        b[i] = a[i] / len;
}

Float:GetAbsVec(const Float:a[])
{
    return SquareRoot(a[0] * a[0] + a[1] * a[1]);
}
// }}}
// }}}

// vim: filetype=cpp foldmethod=marker
