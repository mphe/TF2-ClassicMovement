#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1

// Source: Measuring
#define JUMP_SPEED 283.0

// https://github.com/ValveSoftware/source-sdk-2013/blob/master/mp/src/game/shared/gamemovement.h#L104
#define AIR_CAP 30.0

#define DEBUG

#define PLUGIN_VERSION "1.0.0"


// Variables {{{
// Plugin cvars
new Handle:cvarEnabled      = INVALID_HANDLE;
new Handle:cvarAutohop      = INVALID_HANDLE;
new Handle:cvarSpeedo       = INVALID_HANDLE;
new Handle:cvarMaxspeed     = INVALID_HANDLE;
new Handle:cvarDuckJump     = INVALID_HANDLE;
new Handle:cvarFrametime    = INVALID_HANDLE;

// Engine cvars
new Handle:cvarFriction         = INVALID_HANDLE;
new Handle:cvarStopspeed        = INVALID_HANDLE;
new Handle:cvarAccelerate       = INVALID_HANDLE;
new Handle:cvarAirAccelerate    = INVALID_HANDLE;

// Global settings
new Float:speedcap          = -1.0;
new Float:virtframetime     = 0.01; // 100 tickrate
new bool:enabled            = true;
new bool:allowAutohop       = true;
new bool:defaultSpeedo      = false;
new bool:duckjump           = true;

new Float:sv_friction       = 4.0;
new Float:sv_stopspeed      = 100.0;
new Float:sv_accelerate     = 10.0;
new Float:sv_airaccelerate  = 10.0;

// Player data
// Arrays are 1 bigger than MAXPLAYERS for the convenience of not having to
// write client - 1 every time when using a client id as index.
new Float:customMaxspeed[MAXPLAYERS + 1];
new Float:realMaxSpeeds [MAXPLAYERS + 1];
new Float:tmpvel        [MAXPLAYERS + 1];
new Float:oldangle      [MAXPLAYERS + 1];
new Float:virtticks     [MAXPLAYERS + 1];
new bool:autohop        [MAXPLAYERS + 1];
new bool:showSpeed      [MAXPLAYERS + 1];
new bool:inair          [MAXPLAYERS + 1];
new bool:landframe      [MAXPLAYERS + 1];
new oldbuttons          [MAXPLAYERS + 1];

#if defined DEBUG
new Float:debugSpeed;
new Float:debugVel[3];
new Float:debugProj;
new Float:debugWishdir[2];
new Float:debugAcc;
new Float:debugFrictionDrop;
new Float:debugEyeAngle;
new debugAngle;
new debugVirtTicks;
#endif

public Plugin:myinfo = {
    name            = "Quake Movement",
    author          = "mphe",
    description     = "Quake/HL1 like movement",
    version         = PLUGIN_VERSION,
    url             = "http://www.sourcemod.net"
};
// }}}


// Commands {{{
public Action:toggleAutohop(client, args)
{
    if (!enabled)
        return Plugin_Continue;

    if (allowAutohop)
    {
        if (HandleBoolCommand(client, args, "sm_autohop", autohop))
        {
            if (autohop[client])
                ReplyToCommand(client, "[QM] Autohopping enabled");
            else
                ReplyToCommand(client, "[QM] Autohopping disabled");
        }
    }
    else
    {
        ReplyToCommand(client, "[QM] Autohopping is disabled on this server");
    }
    return Plugin_Handled;
}

public Action:toggleSpeedo(client, args)
{
    if (!enabled)
        return Plugin_Continue;

    if (HandleBoolCommand(client, args, "sm_speed", showSpeed))
        PrintCenterText(client, "");
    return Plugin_Handled;
}

bool:HandleBoolCommand(client, args, const String:cmd[], bool:variable[])
{
    if (args == 0)
        variable[client] = !variable[client];
    else
    {
        new String:buf[5];
        GetCmdArg(1, buf, sizeof(buf));

        if (strcmp(buf, "on", false) == 0)
            variable[client] = true;
        else if (strcmp(buf, "off", false) == 0)
            variable[client] = false;
        else
        {
            decl String:reply[100] = "[QM] Syntax: ";
            StrCat(reply, sizeof(reply), cmd);
            StrCat(reply, sizeof(reply),  " [on|off]");
            ReplyToCommand(client, reply);
            return false;
        }
    }

    return true;
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
    if (allowAutohop != GetConVarBool(convar))
    {
        allowAutohop = GetConVarBool(convar);
        for (new i = 1; i <= MaxClients; i++)
            autohop[i] = allowAutohop;
    }
}

public ChangeMaxspeed(Handle:convar, const String:oldValue[], const String:newValue[])
{
    speedcap = GetConVarFloat(convar);
}

public ChangeFrametime(Handle:convar, const String:oldValue[], const String:newValue[])
{
    virtframetime = GetConVarFloat(convar);
    if (virtframetime < 0.0 || virtframetime >= GetTickInterval())
    {
        virtframetime = 0.0;
        LogError("Virtual frametime negative or too high -> disabled.");
    }

    for (new i = 1; i <= MaxClients; i++)
        virtticks[i] = 0.0;
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

    CreateConVar("quakemovement_version", PLUGIN_VERSION, "Quake Movement version", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_DONTRECORD);
    cvarEnabled   = CreateConVar("qm_enabled",       "1", "Enable/Disable Quake movement.");
    cvarAutohop   = CreateConVar("qm_allow_autohop", "1", "Allow users to jump automatically by holding jump.");
    cvarSpeedo    = CreateConVar("qm_speedo",        "0", "Show speedometer by default.");
    cvarDuckJump  = CreateConVar("qm_duckjump",      "1", "Allow jumping while being ducked.");
    cvarMaxspeed  = CreateConVar("qm_speedcap",   "-1.0", "The maximum speed players can reach. -1 for unlimited.");
    cvarFrametime = CreateConVar("qm_frametime",  "0.01", "Virtual frametime (in seconds) to simulate a higher tickrate. 0 to disable. Values higher than 0.015 have no effect.");

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
    HookConVarChange(cvarFrametime, ChangeFrametime);

    // Update variables in case the plugin gets reloaded
    ChangeEnabled(cvarEnabled, "", "");
    ChangeAutohop(cvarAutohop, "", "");
    ChangeSpeedo(cvarSpeedo, "", "");
    ChangeDuckJump(cvarDuckJump, "", "");
    ChangeMaxspeed(cvarMaxspeed, "", "");
    ChangeFriction(cvarFriction, "", "");
    ChangeStopspeed(cvarStopspeed, "", "");
    ChangeAccelerate(cvarAccelerate, "", "");
    ChangeAirAccelerate(cvarAirAccelerate, "", "");
    ChangeFrametime(cvarFrametime, "", "");

    AutoExecConfig(true);

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

    // Speed correction
    {
        decl Float:vel[3];
        GetVelocity(client, vel);
        new Float:speed = GetAbsVec(vel);

        // Restore speed if above 520
        if (!inair[client] && tmpvel[client] > 520.0)
        {
            ScaleVec(vel, tmpvel[client] / speed);
            DoFriction(client, vel);
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
        }
        else if (speedcap >= 0.0 && speed > speedcap)
        {
            ScaleVec(vel, speedcap / speed);
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
        }
    }

    ShowSpeedo(client);

    // Reset max speed
    SetMaxSpeed(client, realMaxSpeeds[client]);
}

public DoStuffPre(client)
{
    realMaxSpeeds[client] = GetMaxSpeed(client);

    new buttons = GetClientButtons(client);
    decl Float:vel[3], Float:wishdir[3];
    GetVelocity(client, vel);
    GetWishdir(client, buttons, wishdir);

    CheckGround(client);
    HandleJumping(client, buttons, vel);
    DoInterpolation(client, buttons, wishdir, vel);

    if (!inair[client])
        DoMovement(client, vel, wishdir, true);

    oldbuttons[client] = buttons;

#if defined DEBUG
    for (new i = 0; i < 2; i++)
        debugWishdir[i] = wishdir[i];
    for (new i = 0; i < 3; i++)
        debugVel[i] = vel[i];
    decl Float:dir[3];
    GetClientEyeAngles(client, dir);
    debugEyeAngle = 180.0 + dir[1];
    debugAngle = RoundFloat(FloatAbs(dir[1])) % 45;
    if (debugAngle > 30)
        debugAngle = 45 - debugAngle;
#endif
}

DoMovement(client, Float:vel[3], Float:wishdir[3], bool:handleMaxspeed)
{
    new Float:speed = GetAbsVec(vel);

    // Backup speed
    tmpvel[client] = speed;

    if (speed == 0.0)
        return;

    new Float:maxspeed = realMaxSpeeds[client];
    new Float:drop = GetFrictionDrop(client, speed);
    new Float:acc = GetAcceleration(client, maxspeed);

    // No need to intervene if the maximum gainable speed is still below maxspeed
    if (speed - drop + acc <= maxspeed)
        return;

    if (wishdir[0] != 0.0 || wishdir[1] != 0.0)
    {
        DoFriction(client, vel);
        Accelerate(client, vel, wishdir);
    }

    if (handleMaxspeed)
    {
        speed = GetAbsVec(vel);

        // Set calculated speed as new maxspeed to limit the engine in its
        // acceleration, but also to prevent capping.
        if (FloatAbs(speed - realMaxSpeeds[client]) > 0.1)
        {
            customMaxspeed[client] = speed;
            SetMaxSpeed(client, speed);

            // NOTE:
            // There's a small bug, that occurs only when the virtual
            // frametime is so small that the virtual acceleration
            // (during airtime) returned by GetAcceleration() is smaller
            // than 30.
            // Usually (up to a frametime of 0.009375) it doesn't matter,
            // because the acceleartion is higher than 30. Therefore virtual
            // acceleration and real acceleration (as calculated by the
            // engine) come to the same result: 30.
            // But, since there's no way to change the air cap to enforce a
            // lower acceleration (because it's hardcoded in the engine),
            // the engine will use 30 instead of the lower virtual value.
            // This is basically impossible to notice, though, especially
            // with these high interpolation rates.
            // It could be fixed by setting the maxspeed to 0, to prevent
            // the engine from doing any movement, and then setting the
            // velocity using TeleportEntity(), but that seems a bit too
            // overkill.
        }

#if defined DEBUG
        debugSpeed = speed;
#endif
    }
}

DoInterpolation(client, buttons, Float:wishdir[3], Float:vel[3])
{
#if defined DEBUG
    debugVirtTicks = 0;
#endif

    if (virtframetime == 0.0)
        return;

    new Float:angle = GetVecAngle(wishdir);

    if (inair[client] && !InWater(client)
            && buttons == oldbuttons[client]
            && (wishdir[0] != 0 || wishdir[1] != 0))
    {
        // Subtract one for the current frame.
        virtticks[client] += (GetTickInterval() / virtframetime) - 1;

        if (virtticks[client] >= 1.0)
        {
            new ticks = RoundToFloor(virtticks[client]);
            new Float:step = GetAngleDiff(oldangle[client], angle) / (ticks + 1);
            virtticks[client] -= ticks;

            if (step != 0.0)
            {
                new Float:intwishdir[3];
                for (new i = 1; i <= ticks; i++)
                {
                    VecFromAngle(oldangle[client] + step * i, intwishdir);
                    DoMovement(client, vel, intwishdir, false);
                }
                TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
#if defined DEBUG
                debugVirtTicks = ticks;
#endif
            }
        }
    }
    oldangle[client] = angle;
}

HandleJumping(client, buttons, Float:vel[3])
{
    if (!inair[client] && buttons & IN_JUMP)
    {
        // Jumping while crouching or pressing jump while landing?
        if ((duckjump && !(oldbuttons[client] & IN_JUMP) && buttons & IN_DUCK)
                || (autohop[client] && landframe[client]))
        {
            vel[2] = JUMP_SPEED;
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
        }
    }
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
        ScaleVec(vel, scale);

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
        PrintCenterText(client, "realvel: %f\n%f\n%f\npredicted: %f\nmaxspeed: %f, %f\nproj: %f\nwishdir: (%f;%f)\nacc: %f\ndrop: %f %f\neye angle: %f, %i\ninterpolated frames: %i, %f",
                abs, vel[0], vel[1],
                debugSpeed,
                realMaxSpeeds[client], GetMaxSpeed(client),
                debugProj,
                debugWishdir[0], debugWishdir[1],
                debugAcc,
                GetFriction(client), debugFrictionDrop,
                debugEyeAngle, debugAngle,
                debugVirtTicks, virtticks[client]
                );
#else
        PrintCenterText(client, "%f", abs);
#endif
    }
}

// Basically the same accelerate code as in the Quake/GoldSrc/Source engine.
// https://github.com/ValveSoftware/source-sdk-2013/blob/56accfdb9c4abd32ae1dc26b2e4cc87898cf4dc1/sp/src/game/shared/gamemovement.cpp#L1822
Accelerate(client, Float:vel[3], const Float:wishdir[3])
{
    new Float:maxspeed = realMaxSpeeds[client];

    if (inair[client] && maxspeed > AIR_CAP)
        maxspeed = AIR_CAP;

    new Float:currentspeed = DotProduct(vel, wishdir);
    new Float:addspeed = maxspeed - currentspeed;

    if (addspeed < 0)
        return;

    new Float:acc = GetAcceleration(client, realMaxSpeeds[client]);

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
    if (GetEntityFlags(client) & FL_ONGROUND)
    {
        landframe[client] = false;
        if (inair[client])
        {
            inair[client] = false;
            landframe[client] = true;
        }
    }
    else
    {
        inair[client] = true;
    }
}
// }}}


// Helper functions {{{
// Movement related {{{

// Calculate the friction to subtract for a certain speed.
// (virtframetime is not needed at this point, because there's no friction
// in the air)
Float:GetFrictionDrop(client, Float:speed)
{
    new Float:friction = sv_friction * GetFriction(client);
    new Float:control = (speed < sv_stopspeed) ? sv_stopspeed : speed;
    return (control * friction * GetTickInterval());
}

// Calculate the acceleration based on a given maxspeed.
Float:GetAcceleration(client, Float:maxspeed)
{
    // Water can be ignored I think (at least it works without special treatment)
    new Float:frametime;
    if (inair[client] && virtframetime != 0.0)
        frametime = virtframetime;
    else
        frametime = GetTickInterval();

    return (inair[client] ? sv_airaccelerate : sv_accelerate)
        * frametime * maxspeed * GetFriction(client);
}

// Fills the fwd and right vector with a normalized vector pointing in the
// direction the client is looking and the right of it.
// fwd and right must be 3D vectors, although their z value is always zero.
GetViewAngle(client, Float:fwd[3], Float:right[3])
{
    GetClientEyeAngles(client, fwd);
    VecFromAngle(fwd[1], fwd);
    right[0] = fwd[1];
    right[1] = -fwd[0];
    fwd[2] = right[2] = 0.0;
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
// }}}

// Setup, Variables, Misc, ... {{{
SetupClient(client)
{
    if (IsFakeClient(client) || client < 1 || client > MAXPLAYERS)
        return;

    autohop[client] = allowAutohop;
    showSpeed[client] = defaultSpeedo;
    oldbuttons[client] = 0;
    virtticks[client] = 0.0;
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
    return GetEntPropFloat(client, Prop_Data, "m_flFriction");
}

bool:InWater(client)
{
    // Double negate to avoid tag mismatch warning
    return !!(GetEntityFlags(client) & FL_INWATER);
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

// Math {{{

// Returns a signed difference between two angles.
Float:GetAngleDiff(Float:a, Float:b)
{
    // Apparently there's no float modulo function
    return float(RoundFloat(b - a + 180.0) % 360) - 180;
}

// 2D Vector functions {{{

ScaleVec(Float:vec[], Float:scale)
{
    for (new i = 0; i < 2; i++)
        vec[i] *= scale;
}

Float:DotProduct(const Float:a[], const Float:b[])
{
    return a[0] * b[0] + a[1] * b[1];
}

Float:GetAbsVec(const Float:a[])
{
    return SquareRoot(a[0] * a[0] + a[1] * a[1]);
}

Float:GetVecAngle(const Float:vec[])
{
    return RadToDeg(ArcTangent2(vec[1], vec[0]));
}

VecFromAngle(Float:angle, Float:vec[])
{
    vec[0] = Cosine(DegToRad(angle));
    vec[1] = Sine(DegToRad(angle));
}
// }}}
// }}}
// }}}

// vim: filetype=cpp foldmethod=marker
