#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1

// Taken from "Fysics Control" plugin, it seems right.
#define JUMP_SPEED 300.0

// https://github.com/ValveSoftware/source-sdk-2013/blob/master/mp/src/game/shared/gamemovement.h#L104
#define AIR_CAP 30.0

#define PI 3.14159

#define DEBUG
// #define SKIP_FRICITON

// TODO: version cvar, test speedap

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
    RegConsoleCmd("sm_autohop", toggleAutohop, "Toggle autohopping on/off");

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
        if (IsClientConnected(i))
            SetupClient(i);
}

public OnClientPutInServer(client)
{
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


// Main {{{
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

    new buttons = GetClientButtons(client);
    decl Float:vel[3];
    GetVelocity(client, vel);

    CheckGround(client);
    HandleJumping(client, buttons, vel);
    DoMovement(client, vel, buttons);

#if defined DEBUG
    decl Float:dir[3];
    GetClientEyeAngles(client, dir);
    debugEyeAngle = ConvertAngle(dir[1]);
    debugAngle = RoundFloat(FloatAbs(dir[1])) % 45;
    if (debugAngle > 30)
        debugAngle = 45 - debugAngle;
#endif
}

DoMovement(client, Float:vel[3], buttons)
{
    new Float:speed = GetAbsVec(vel);
    tmpvel[client] = speed;

    if (speed == 0.0)
        return;

    // if (inair[client])
    // {
    //     // SetMaxSpeed(client, 10000.0); // Breaks cloak and dagger
    //     return;
    // }

    new Float:maxspeed = realMaxSpeeds[client];
    new Float:drop = GetFrictionDrop(client, speed);
    new Float:acc = GetAcceleration(client, maxspeed);

    // No need to intervene if the maximum gainable speed is still below maxspeed
    if (speed - drop + acc <= maxspeed)
        return;

    decl Float:wishdir[3];
    GetWishdir(client, buttons, wishdir);

    if (wishdir[0] != 0.0 || wishdir[1] != 0.0)
    {
        DoFriction(client, vel);
        Accelerate(client, vel, wishdir, inair[client]);
    }

    speed = GetAbsVec(vel);

    // Reuse maxspeed to store the new maxspeed
    if (speedcap < 0.0)
        maxspeed = speed;
    else
        maxspeed = speed < speedcap ? speed : speedcap;

    // Set calculated speed as new maxspeed to limit the engine in its
    // acceleration, but also to prevent capping.
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
}

HandleJumping(client, buttons, Float:vel[3])
{
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
        PrintCenterText(client, "realvel: %f\n%f\n%f\npredicted: %f\n%f\n%f\nmaxspeed: %f, %f\nproj: %f\nwishdir: (%f;%f)\nacc: %f\ndrop: %f %f\neyeangle: %f\nangle: %i",
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

// Basically the same accelerate code as in the Quake/GoldSrc/Source engine.
// https://github.com/ValveSoftware/source-sdk-2013/blob/56accfdb9c4abd32ae1dc26b2e4cc87898cf4dc1/sp/src/game/shared/gamemovement.cpp#L1822
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
// }}}


// Helper functions {{{

// Calculate the friction to subtract for a certain speed.
Float:GetFrictionDrop(client, Float:speed)
{
    new Float:friction = sv_friction * GetFriction(client);
    new Float:control = (speed < sv_stopspeed) ? sv_stopspeed : speed;
    return (control * friction * GetTickInterval());
}


// Calculate the acceleration based on a given maxspeed.
Float:GetAcceleration(client, Float:maxspeed, bool:air = false)
{
    return (air ? sv_airaccelerate : sv_accelerate) * GetTickInterval() * maxspeed * GetFriction(client);
}

// Convert the 0-180, 0-(-180) angles (as in GetClientEyeAngles) to 0-360.
Float:ConvertAngle(Float:angle)
{
    return angle < 0.0 ? 360.0 + angle : angle;
}

// Fills the fwd and right vector with a normalized vector pointing in the
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
SetupClient(client)
{
    autohop[client] = defaultAutohop;
    showSpeed[client] = defaultSpeedo;
    SDKHook(client, SDKHook_PreThink, OnPreThink);
    SDKHook(client, SDKHook_PostThink, OnPostThink);
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
// }}}

// 2D Vector functions {{{
Float:DotProduct(const Float:a[], const Float:b[])
{
    return a[0] * b[0] + a[1] * b[1];
}

Float:GetAbsVec(const Float:a[])
{
    return SquareRoot(a[0] * a[0] + a[1] * a[1]);
}
// }}}
// }}}

// vim: filetype=cpp foldmethod=marker
