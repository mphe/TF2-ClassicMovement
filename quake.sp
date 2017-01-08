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
// #define USE_ACCELERATE_REPLICA

// TODO: backwards speed, doors -.-, autohop duckjump, dos2unix,
//       tweak wall dist, remove jump-boost code

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
new Float:touchvec      [MAXPLAYERS + 1][3];
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
new Float:debugFriction;
new Float:debugFrictionDrop;
#endif

#if defined DEBUG
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
    RegConsoleCmd("sm_autohop", toggleAutohop, "Toggle autohopping on/off");

    cvarEnabled = CreateConVar("qm_enabled", "1",
            "Enable/Disable Quake movement.", FCVAR_PLUGIN);
    cvarAutohop = CreateConVar("qm_autohop", "1",
            "Automatically jump while holding jump.", FCVAR_PLUGIN);
    cvarSpeedo = CreateConVar("qm_speedo", "0",
            "Show speedometer.", FCVAR_PLUGIN);
    cvarDuckJump = CreateConVar("qm_duckjump", "1",
            "Allow jumping while being ducked.", FCVAR_PLUGIN);
    cvarMaxspeed = CreateConVar("qm_maxspeed", "-1.0",
            "The maximum speed players can reach.", FCVAR_PLUGIN);
    cvarFricOffset = CreateConVar("qm_friction_offset", "0",
            "Constant subtracted to the friction. Don't use if you don't know what you do.", FCVAR_PLUGIN);

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

public OnThinkPost(client)
{
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
    GetVelocity(client, touchvec[client]);
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

    decl Float:wallvec[2];
    { // Wall collision
        if (touched[client])
            touched[client] = GetWallVec(client, wishdir, wallvec);
    }

    decl Float:speeddir[2];
    GetUnitVec(newvel, speeddir);

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
                new Float:drop = landframe[client] ? 0.0 : GetFrictionDrop(client, tmpvel[client]);
                for (new i = 0; i < 2; i++)
                    newvel[i] = speeddir[i] * (tmpvel[client] - drop);
            }

            // Jumping while crouching
            if (duckjump && !jumpPressed[client] && buttons & IN_JUMP && buttons & IN_DUCK)
            {
                newvel[2] = JUMP_SPEED;
                if (newvel[0] == 0.0 && newvel[1] == 0.0)
                {
                    decl Float:fwd[3], Float:right[3];
                    GetViewAngle(client, fwd, right);
                    for (new i = 0; i < 2; i++)
                        newvel[i] += fwd[i] * 600;
                }
                else
                {
                    for (new i = 0; i < 2; i++)
                        newvel[i] += speeddir[i] * 600;
                }
            }
        }

        // Double negate to prevent tag mismatch warning
        jumpPressed[client] = !!(buttons & IN_JUMP);
    }
    // }}}

    DoMovement(client, newvel, wallvec, wishdir);

    if ((touched[client] || !inair[client]) && (newvel[0] != realvel[0] || newvel[1] != realvel[1] || newvel[2] != realvel[2]))
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newvel);

    for (new i = 0; i < 3; i++)
        oldvel[client][i] = newvel[i];

    touched[client] = false;

    // Reset max speed
    SetMaxSpeed(client, realMaxSpeeds[client]);
}

DoMovement(client, Float:newvel[3], Float:wallvec[2], Float:wishdir[3])
{
    new Float:speed = GetAbsVec(newvel);

    // TODO: Check if this expression is right and document why
    if (speed != 0.0 && wishdir[0] != 0.0 && wishdir[1] != 0.0)
    {
        if (touched[client])
            WallAccelerate(client, newvel, speed, wishdir);
        else
            Accelerate(client, newvel, speed, wishdir);

        speed = GetAbsVec(newvel);
    }

#if defined DEBUG
        debugSpeed = speed;
        for (new i = 0; i < 3; i++)
            debugVel[i] = newvel[i];
        for (new i = 0; i < 2; i++)
            debugWishdir[i] = wishdir[i];
#endif

    tmpvel[client] = speed;

    // Speedmeter
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
                GetAngleBetween(wishdir, wallvec)
                );
#else
        PrintCenterText(client, "%f", speed);
#endif
    }
}

DoFriction(client, Float:vel[3], bool:interpolate = true)
{
    if (inair[client] || landframe[client])
        return;

    new Float:speed = GetAbsVec(vel);
    if (speed > realMaxSpeeds[client] + 1)
    {
        new Float:drop = GetFrictionDrop(client, speed);
        if (interpolate)
            drop -= GetFrictionInterpolation(realMaxSpeeds[client]);

#if defined DEBUG
        debugFrictionDrop = drop;
#endif
        new Float:newspeed = (speed - drop) / speed;
        if (newspeed > 0.1)
            for (new i = 0; i < 2; i++)
                vel[i] = vel[i] * newspeed;
    }
}
// }}}

// Helper functions {{{
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

bool:GetWallVec(client, const Float:dir[3], Float:wallvec[2])
{
    decl Float:origin[3], Float:angles[3];

    // GetClientAbsOrigin(client, origin);
    GetClientEyePosition(client, origin);
    GetVectorAngles(dir, angles);

    new Handle:ray = TR_TraceRayFilterEx(origin, angles, MASK_SHOT,
            RayType_Infinite, TR_FilterSelf, client);

    if (TR_DidHit(ray))
    {
        decl Float:normal[3], Float:endpos[3];
        TR_GetPlaneNormal(ray, normal);
        TR_GetEndPosition(endpos, ray);
        new Float:dist = GetVectorDistance(origin, endpos, false);

        wallvec[0] = normal[1];
        wallvec[1] = -normal[0];

#if defined DEBUG
        PrintToServer("wallvec: %f, %f dist: %f touchvec: %f, %f",
                wallvec[0], wallvec[1],
                dist,
                touchvec[client][0], touchvec[client][1]);
#endif

        // If the z part is not 0, it's not a wall.
        if (normal[2] == 0.0 && dist < 60.0)
        {
            CloseHandle(ray);
            return true;
        }
    }

    CloseHandle(ray);
    return false;
}

#if defined USE_ACCELERATE_REPLICA
// NOTE: Does not work (anymore), but keep it for now
Accelerate(client, Float:newvel[3], Float:speed, const Float:wishdir[3])
{
    // currentspeed = DotProduct (pmove.velocity, wishdir);
    // addspeed = wishspeed - currentspeed;
    // if (addspeed <= 0)
    //     return;
    // accelspeed = accel*frametime*wishspeed;
    // if (accelspeed > addspeed)
    //     accelspeed = addspeed;

    new Float:maxspeed = realMaxSpeeds[client];
    // new Float:currentspeed = DotProduct(oldvel[client], wishdir);

    // quake
    // new Float:maxaddspeed = maxspeed - currentspeed;
    // if (maxaddspeed <= 0) // If maxspeed already reached
    //     return;

    new Float:oldspeed = GetAbsVec(oldvel[client]);
    // new Float:acc = speed - oldspeed;

    new Float:accvec[2];
    for (new i = 0; i < 2; i++)
        accvec[i] = newvel[i] - oldvel[client][i];
    new Float:acc = GetAbsVec(accvec);

    if (acc < 0.1)
        return;

    decl Float:speeddir[2];
    GetUnitVec(accvec, speeddir);
    // GetUnitVec(newvel, speeddir);

    new Float:currentspeed = DotProduct(oldvel[client], speeddir);
    // new Float:currentspeed = DotProduct(oldvel[client], wishdir);
    new Float:maxaddspeed = maxspeed - currentspeed;

    // if (maxaddspeed > 0)
    {
        PrintToServer("----------");
        PrintToServer("oldvel: %f, %f abs: %f", oldvel[client][0], oldvel[client][1], oldspeed);
        PrintToServer("newvel: %f, %f abs: %f", newvel[0], newvel[1], speed);
        PrintToServer("accvec: %f, %f abs: %f", accvec[0], accvec[1], acc);
        PrintToServer("wishdir: %f, %f", wishdir[0], wishdir[1]);
    }

    DoFriction(client, oldvel[client], false);

    // quake
    // if (acc > maxaddspeed)
    //     acc = maxaddspeed;

    if (currentspeed + acc > maxspeed)
        acc = maxspeed - currentspeed;

    for (new i = 0; i < 2; i++)
        newvel[i] = oldvel[client][i] + speeddir[i] * acc;
        // newvel[i] = speeddir[i] * (oldspeed + acc);

#if defined DEBUG
    debugVelDir[0] = speeddir[0];
    debugVelDir[1] = speeddir[1];
    debugOldspeed = oldspeed;
    debugProj = currentspeed;
    debugAcc = acc;
#endif
}
#else
// Calculates the acceleration between the last and the current frame, adds
// it together the "Quake way" and stores it in newvel.
// newvel: The (untouched) velocity vector
// speed: abs(newvel)
// wishdir: The acceleration direction (normalized)
Accelerate(client, Float:newvel[3], Float:speed, const Float:wishdir[3])
{
    new Float:maxspeed = realMaxSpeeds[client];
    new Float:currentspeed = DotProduct(oldvel[client], wishdir);

    new Float:oldspeed = GetAbsVec(oldvel[client]);
    new Float:acc = speed - oldspeed;

    if (currentspeed + acc > maxspeed)
        acc = maxspeed - currentspeed;

    decl Float:speeddir[2];
    GetUnitVec(newvel, speeddir);

    for (new i = 0; i < 2; i++)
        newvel[i] = speeddir[i] * (oldspeed + acc);

#if defined DEBUG
    debugVelDir[0] = speeddir[0];
    debugVelDir[1] = speeddir[1];
    debugOldspeed = oldspeed;
    debugProj = currentspeed;
    debugAcc = acc;
#endif
}
#endif

WallAccelerate(client, Float:newvel[3], Float:speed, const Float:wishdir[3])
{
    // DoFriction(client, oldvel[client]);

    new Float:maxspeed = realMaxSpeeds[client];
    new Float:oldspeed = GetAbsVec(oldvel[client]);

    new Float:acc = speed - oldspeed;

    // New vel was clipped by the engine, so the following works
    new Float:currentspeed = DotProduct(newvel, wishdir);

    if (currentspeed + acc > maxspeed)
        acc = maxspeed - currentspeed;

    decl Float:speeddir[2];
    GetUnitVec(newvel, speeddir);

    for (new i = 0; i < 2; i++)
        newvel[i] = speeddir[i] * (oldspeed + acc);

    DoFriction(client, newvel);

    // if (maxaddspeed > 0)
    {
        PrintToServer("----------");
        PrintToServer("oldvel: %f, %f abs: %f", oldvel[client][0], oldvel[client][1], oldspeed);
        PrintToServer("newvel: %f, %f abs: %f", newvel[0], newvel[1], speed);
        // PrintToServer("accvec: %f, %f abs: %f", accvec[0], accvec[1], acc);
        PrintToServer("wishdir: %f, %f", wishdir[0], wishdir[1]);
    }

#if defined DEBUG
    debugVelDir[0] = speeddir[0];
    debugVelDir[1] = speeddir[1];
    debugOldspeed = oldspeed;
    debugProj = currentspeed;
    debugAcc = acc;
#endif
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

public bool:TR_FilterSelf(ent, mask, any:data)
{
    return ent != data;
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

HookClient(client)
{
    SDKHook(client, SDKHook_PreThink, OnPreThink);
    SDKHook(client, SDKHook_ThinkPost, OnThinkPost);
    SDKHook(client, SDKHook_PostThink, OnPostThink);
    SDKHook(client, SDKHook_Touch, OnTouch);
}

SetupClient(client)
{
    autohop[client] = defaultAutohop;
    showSpeed[client] = defaultSpeedo;
}

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
