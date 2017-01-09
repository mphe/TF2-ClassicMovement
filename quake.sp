#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smlib>
#include <tf2_stocks>

#pragma semicolon 1

#define JUMP_SPEED 300.0
#define FRAMETIME 0.015 // 66.666666
#define PI 3.14159
#define DEBUG
#define MAX_STEP_HEIGHT 18 // https://developer.valvesoftware.com/wiki/Team_Fortress_2_Mapper's_Reference#Other_Info

// TODO: backwards speed, doors -.-, autohop duckjump, disable for spectators
//       version cvar, spy invisibility (fuck -.-),
//       check if airtime is skippable

// Variables {{{
new Handle:cvarEnabled   = INVALID_HANDLE;
new Handle:cvarAutohop   = INVALID_HANDLE;
new Handle:cvarSpeedo    = INVALID_HANDLE;
new Handle:cvarMaxspeed  = INVALID_HANDLE;
new Handle:cvarDuckJump  = INVALID_HANDLE;
new Handle:cvarFriction  = INVALID_HANDLE;
new Handle:cvarStopspeed = INVALID_HANDLE;

// Global settings
new bool:enabled = true;
new bool:defaultAutohop = true;
new bool:defaultSpeedo = false;
new bool:duckjump = true;
new Float:speedcap = -1.0;
new Float:sv_friction = 4.0;
new Float:sv_stopspeed = 100.0;

// Player data
// Arrays are 1 bigger than MAXPLAYERS for the convenience of not having to
// write client - 1 every time when using a client id as index.
new Float:oldvel        [MAXPLAYERS + 1][3];
new Float:realMaxSpeeds [MAXPLAYERS + 1];
new Float:tmpvel        [MAXPLAYERS + 1];
new bool:autohop        [MAXPLAYERS + 1];
new bool:showSpeed      [MAXPLAYERS + 1];
new bool:inair          [MAXPLAYERS + 1];
new bool:landframe      [MAXPLAYERS + 1];
new bool:jumpPressed    [MAXPLAYERS + 1];
new bool:touched        [MAXPLAYERS + 1];

#if defined DEBUG
new Float:debugSpeed;
new Float:debugVel[3];
new Float:debugVelDir[2];
new Float:debugOldspeed;
new Float:debugProj;
new Float:debugWishdir[2];
new Float:debugAcc;
new Float:debugFrictionDrop;
new Float:debugAngle;

new Handle:cvarFricOffset = INVALID_HANDLE;
new Float:frictionOffset = 0.0;
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

#if defined DEBUG
public ChangeFrictionOffset(Handle:convar, const String:oldValue[], const String:newValue[])
{
    frictionOffset = GetConVarFloat(convar);
}
#endif
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

    sv_friction = GetConVarFloat(cvarFriction);
    sv_stopspeed = GetConVarFloat(cvarStopspeed);

    HookConVarChange(cvarEnabled, ChangeEnabled);
    HookConVarChange(cvarAutohop, ChangeAutohop);
    HookConVarChange(cvarSpeedo, ChangeSpeedo);
    HookConVarChange(cvarDuckJump, ChangeDuckJump);
    HookConVarChange(cvarMaxspeed, ChangeMaxspeed);
    HookConVarChange(cvarFriction, ChangeFriction);
    HookConVarChange(cvarStopspeed, ChangeStopspeed);

#if defined DEBUG
    cvarFricOffset = CreateConVar("qm_friction_offset", "0",
            "Constant subtracted to the friction. Don't use if you don't know what you do.");
    HookConVarChange(cvarFricOffset, ChangeFrictionOffset);
#endif

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
    if (!enabled)
        return;

    realMaxSpeeds[client] = GetMaxSpeed(client);
    if (speedcap < 0.0)
        SetMaxSpeed(client, 100000.0);
    else
        SetMaxSpeed(client, speedcap);
}

public OnPostThink(client)
{
    DoStuff(client);
}

public OnTouch(client, other)
{
    if (!enabled || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    if (other > 0 && other <= MaxClients)
        return;

    touched[client] = true;
}
// }}}

// Movement functions {{{
public DoStuff(client)
{
    if (!enabled || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    // Catch weapon related speed boosts (they don't appear in PreThink)
    if (GetMaxSpeed(client) != 100000.0)
        realMaxSpeeds[client] = GetMaxSpeed(client);

    decl Float:newvel[3], Float:realvel[3];
    GetVelocity(client, newvel);
    GetVelocity(client, realvel);

    new buttons = GetClientButtons(client);

    decl Float:wishdir[3];
    GetWishdir(client, buttons, wishdir);

    // Check if colliding with a wall
    if (touched[client])
    {
        decl Float:normal[3];
        touched[client] = GetWallNormal(client, wishdir, normal);

#if defined DEBUG
        if (touched[client])
        {
            decl Float:wallvec[2];
            wallvec[0] = normal[1];
            wallvec[1] = -normal[0];
            debugAngle = GetAngleBetween(wishdir, wallvec);
            PrintToServer("wallvec: %f, %f", wallvec[0], wallvec[1]);
        }
#endif
    }

    // collision ground {{{
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
                // Pressing jump while landing?
                if (autohop[client] && buttons & IN_JUMP)
                    newvel[2] = JUMP_SPEED;
                inair[client] = false;
                landframe[client] = true;
            }

            // Restore speed if above 520
            // TODO: Check if this friction interferes with the friction
            //       applied when wallstrafing
            if (tmpvel[client] > 520.0)
            {
                decl Float:speeddir[2];
                GetUnitVec(newvel, speeddir);
                new Float:drop = landframe[client] ? 0.0 : GetFrictionDrop(client, tmpvel[client]);
                for (new i = 0; i < 2; i++)
                    newvel[i] = speeddir[i] * (tmpvel[client] - drop);
            }

            // Jumping while crouching
            if (duckjump && !jumpPressed[client] && buttons & IN_JUMP && buttons & IN_DUCK)
                newvel[2] = JUMP_SPEED;
        }

        // Double negate to prevent tag mismatch warning
        jumpPressed[client] = !!(buttons & IN_JUMP);
    }
    // }}}

    DoMovement(client, newvel, wishdir);
    ShowSpeedo(client);

    if ((touched[client] || !inair[client]) && (newvel[0] != realvel[0] || newvel[1] != realvel[1] || newvel[2] != realvel[2]))
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newvel);

    for (new i = 0; i < 3; i++)
        oldvel[client][i] = newvel[i];

    touched[client] = false;

    // Reset max speed
    SetMaxSpeed(client, realMaxSpeeds[client]);
}

DoMovement(client, Float:newvel[3], Float:wishdir[3])
{
    Accelerate(client, newvel, wishdir);

    if (touched[client])
        DoFriction(client, newvel);

    // Backup speed to restore it later in case it is over 520
    tmpvel[client] = GetAbsVec(newvel);

#if defined DEBUG
    debugSpeed = tmpvel[client];
    for (new i = 0; i < 3; i++)
        debugVel[i] = newvel[i];
    for (new i = 0; i < 2; i++)
        debugWishdir[i] = wishdir[i];
#endif
}

DoFriction(client, Float:vel[3], bool:interpolate = true)
{
    if (inair[client] || landframe[client])
        return;

    new Float:speed = GetAbsVec(vel);

    // if (speed > realMaxSpeeds[client] + 1)
    if (speed > 0.001)
    {
        new Float:drop = GetFrictionDrop(client, speed);
        if (interpolate)
            drop -= GetFrictionInterpolation(realMaxSpeeds[client]);

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
// }}}

// Helper functions {{{
// Movement related {{{
// Checks for collisions in a given direction using the client's bounding box.
// If a collision was found, the collding entity's normal is stored in the
// given normal vector.
// Additionally, it will check if the colliding object is actually a wall.
// If yes, it will return true, otherwise false.
bool:GetWallNormal(client, const Float:wishdir[3], Float:normal[3])
{
    decl Float:origin[3], Float:mins[3], Float:maxs[3];
    GetEntPropVector(client, Prop_Data, "m_vecOrigin", origin);
    GetEntPropVector(client, Prop_Data, "m_vecMins", mins);
    GetEntPropVector(client, Prop_Data, "m_vecMaxs", maxs);
    origin[2] += MAX_STEP_HEIGHT + 1;
    maxs[2] -= MAX_STEP_HEIGHT + 1;

    new Float:dest[3];
    AddVectors(dest, wishdir, dest);
    ScaleVector(dest, 10.0);
    AddVectors(origin, dest, dest);

    // "Trace on" - Shirou
    new Handle:trace = TR_TraceHullFilterEx(origin, dest, mins, maxs,
            MASK_SHOT, TR_FilterSelf, client);

    if (TR_DidHit(trace))
    {
        TR_GetPlaneNormal(trace, normal);

        // If the z part is not 0, it's not a wall.
        // The second check is necessary because automatic doors sometimes
        // have a null normal apparently.
        if (normal[2] == 0.0 && (normal[0] != 0.0 || normal[1] != 0.0))
        {
            CloseHandle(trace);
            return true;
        }
    }

    CloseHandle(trace);
    return false;
}

// Calculates the acceleration between the last and the current frame, adds
// it together the "Quake way" and stores it in newvel.
// newvel: The (untouched) velocity vector
// wishdir: The acceleration direction (normalized)
Accelerate(client, Float:newvel[3], const Float:wishdir[3])
{
    new Float:speed = GetAbsVec(newvel);

    // TODO: Check if this expression is right and document why
    if (speed == 0.0 || wishdir[0] == 0.0 || wishdir[1] == 0.0)
        return;

    new Float:maxspeed = realMaxSpeeds[client];
    new Float:oldspeed = GetAbsVec(oldvel[client]);
    new Float:acc = speed - oldspeed;

    // TODO: Check if this needs to be seperated
    new Float:currentspeed;
    if (touched[client])
        currentspeed = DotProduct(newvel, wishdir);
    else
        currentspeed = DotProduct(oldvel[client], wishdir);

    if (currentspeed + acc > maxspeed)
        acc = maxspeed - currentspeed;

    decl Float:speeddir[2];
    GetUnitVec(newvel, speeddir);

    for (new i = 0; i < 2; i++)
        newvel[i] = speeddir[i] * (oldspeed + acc);

#if defined DEBUG
    if (touched[client])
    {
        PrintToServer("----------");
        PrintToServer("oldvel: %f, %f abs: %f", oldvel[client][0], oldvel[client][1], oldspeed);
        PrintToServer("newvel: %f, %f abs: %f", newvel[0], newvel[1], speed);
        PrintToServer("wishdir: %f, %f", wishdir[0], wishdir[1]);
    }
    debugVelDir[0] = speeddir[0];
    debugVelDir[1] = speeddir[1];
    debugOldspeed = oldspeed;
    debugProj = currentspeed;
    debugAcc = acc;
#endif
}

// For some reason (I assume because the engine's internal friction handling
// messes it up), wallstrafing behaves strange, meaning the maximum
// wallstrafe speed is higher or lower as it should be, or the angle to the
// wall, where the maximum is achived is not about 7-8°.
// It can be fixed by subtracting a certain value from the friction that
// this plugin applies (-> WallstrafeAccelerate and DoFriction()).
// For small speeds (< 280) the optimum angle is still about 3° off, but the
// maximum achievable speed is correct.
// Some maxspeeds are still a bit off, e.g. Spy (320 speed) should have a
// wallstrafe maxspeed of 489 but instead it goes up to 491.
// This is because I use the linear function below to calculate the offset,
// rather than hardcoding the measured values that would fit "perfectly".
// Although the perfectionist in me is screaming that I should fix it,
// it's good enough for now.
Float:GetFrictionInterpolation(Float:maxspeed)
{
    // Measured values:
    // 320.0: 13.2
    // 300.0: 10.3
    // 280.0:  7.3
    // 240.0:  1.5 // ~56°
    // 230.0:  0.3 // ~56°

    return (6.0 / 40.0) * (maxspeed - 230.0) + 0.3;
}

Float:GetFriction(client)
{
    // Not sure if this will ever be different than 1.0, but let's use this
    // anyway just to be sure.
    return GetEntPropFloat(client, Prop_Data, "m_flFriction");
}

// Caluclate the friction to subtract for a certain speed.
Float:GetFrictionDrop(client, Float:speed)
{
    new Float:friction = sv_friction * GetFriction(client);
    new Float:control = (speed < sv_stopspeed) ? sv_stopspeed : speed;
#if defined DEBUG
    return (control * friction * FRAMETIME) - frictionOffset;
#else
    return (control * friction * FRAMETIME);
#endif
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

        wishdir[2] = 0.0;     // we don't care for the z axis
        NormalizeVector(wishdir, wishdir);
    }
}
// }}}

// Setup, Variables, Misc, ... {{{
ShowSpeedo(client)
{
    if (showSpeed[client])
    {
#if defined DEBUG
        PrintCenterText(client, "new: %f\n%f\n%f\nspeeddir: %f;%f\nmaxspeed: %f, %f\noldspeed: %f\nproj: %f\nwishdir: (%f;%f)\nacc: %f\ndrop: %f %f\nangle: %f",
                debugSpeed, debugVel[0], debugVel[1],
                debugVelDir[0], debugVelDir[1],
                realMaxSpeeds[client], GetMaxSpeed(client),
                debugOldspeed,
                debugProj,
                debugWishdir[0], debugWishdir[1],
                debugAcc,
                GetFriction(client), debugFrictionDrop,
                debugAngle
                );
#else
        PrintCenterText(client, "%f", speed);
#endif
    }
}

HookClient(client)
{
    SDKHook(client, SDKHook_PreThink, OnPreThink);
    SDKHook(client, SDKHook_PostThink, OnPostThink);
    SDKHook(client, SDKHook_Touch, OnTouch);
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
