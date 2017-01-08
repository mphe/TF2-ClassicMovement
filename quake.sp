#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smlib>
#include <tf2_stocks>

#define JUMP_SPEED 300.0

// TODO: backwards speed

// Variables {{{
new Handle:cvarEnabled  = INVALID_HANDLE;
new Handle:cvarAutohop  = INVALID_HANDLE;
new Handle:cvarSpeedo   = INVALID_HANDLE;
new Handle:cvarMaxspeed = INVALID_HANDLE;
new Handle:cvarDuckJump = INVALID_HANDLE;

// Global settings
new bool:enabled = true;
new bool:defaultAutohop = true;
new bool:defaultSpeedo = false;
new bool:duckjump = true;
new Float:speedcap = -1.0;

// Player data
// Arrays are 1 bigger than MAXPLAYERS for the convenience of not having to
// write client - 1 every time when using a client id as index.
new Float:oldvel[MAXPLAYERS + 1][2];
new Float:tmpvel[MAXPLAYERS + 1][2];
new Float:realMaxSpeeds[MAXPLAYERS + 1];
new bool:autohop[MAXPLAYERS + 1];
new bool:showSpeed[MAXPLAYERS + 1];
new bool:inair[MAXPLAYERS + 1];
new bool:jumpPressed[MAXPLAYERS + 1];

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
// }}}

// Events {{{
public OnPluginStart()
{
    RegConsoleCmd("sm_speed", toggleSpeedo, "Toggle speedometer on/off");
    RegConsoleCmd("sm_autohop", toggleAutohop, "Toggle autohopping on/off");

    cvarEnabled = CreateConVar("qm_enabled", "1",
            "Enable/Disable Quake movement", FCVAR_PLUGIN);
    cvarAutohop = CreateConVar("qm_autohop", "1",
            "Automatically jump while holding jump", FCVAR_PLUGIN);
    cvarSpeedo = CreateConVar("qm_speedo", "0",
            "Show speedometer", FCVAR_PLUGIN);
    cvarDuckJump = CreateConVar("qm_duckjump", "1",
            "Allow jumping while being ducked", FCVAR_PLUGIN);
    cvarMaxspeed = CreateConVar("qm_maxspeed", "-1.0",
            "The maximum speed players can reach", FCVAR_PLUGIN);

    HookConVarChange(cvarEnabled, ChangeEnabled);
    HookConVarChange(cvarAutohop, ChangeAutohop);
    HookConVarChange(cvarSpeedo, ChangeSpeedo);
    HookConVarChange(cvarDuckJump, ChangeDuckJump);
    HookConVarChange(cvarMaxspeed, ChangeMaxspeed);

    for (new i = 1; i <= MaxClients; i++)
    {
        if (Client_IsValid(i))
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
    // Increase the max speed to be always way above the current speed to
    // bypass the engine's capping mechanism.
    if (enabled)
    {
        realMaxSpeeds[client] = GetMaxSpeed(client);
        if (speedcap < 0.0)
            SetMaxSpeed(client, realMaxSpeeds[client] + GetAbsVec(oldvel[client]));
        else
            SetMaxSpeed(client, speedcap);
    }

    decl Float:newvel[3], Float:speed;
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", newvel);
    speed = GetAbsVec(newvel);

    if (speed > 400.0)
    {
        decl Float:speeddir[2];
        GetUnitVec(newvel, speeddir);
        new Float:sub = speed - 400.0;

        for (new i = 0; i < 2; i++)
        {
            tmpvel[client][i] = sub * speeddir[i];
            newvel[i] -= sub * speeddir[i];
        }
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newvel);
    }
    else
    {
        for (new i = 0; i < 2; i++)
            tmpvel[client][i] = 0.0;
    }
}

public OnPostThink(client)
{
    if (!enabled || !IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    new Float:diff;
    diff = GetMaxSpeed(client) - (realMaxSpeeds[client] + GetAbsVec(oldvel[client]))

    decl Float:newvel[3], Float:realspeed;
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", newvel);
    realspeed = GetAbsVec(newvel);

    for (new i = 0; i < 2; i++)
        newvel[i] += tmpvel[client][i];

    new buttons = GetClientButtons(client);
    CheckJumping(client, buttons, newvel);

    new Float:speed = GetAbsVec(newvel);

    // Speed control
    if (speed != 0.0)
    {
        new Float:maxspeed = realMaxSpeeds[client];
        new Float:oldspeed = GetAbsVec(oldvel[client]);
        new Float:acc = speed - oldspeed;

        decl Float:speeddir[2];
        GetUnitVec(newvel, speeddir);

        // Stores in which direction the player wants to move
        decl Float:wishdir[3];
        GetWishdir(client, buttons, wishdir);

        new Float:proj = DotProduct(oldvel[client], wishdir);
        if (proj + acc > maxspeed)
            acc = maxspeed - proj;

        for (new i = 0; i < 2; i++)
            newvel[i] = speeddir[i] * (oldspeed + acc);

        speed = GetAbsVec(newvel);

        // Debug speedometer
        if (showSpeed[client])
        {
            PrintCenterText(client, "new: %f\n%f\n%f\n%f\nrealspeed: %f\ntmpvel: %f; %f\nspeeddir: %f;%f\nmaxspeed: %f, %f\noldspeed: %f\nproj: %f\nwishdir: (%f;%f)\nacc: %f\ndiff: %f",
                    (speed), (newvel[0]), (newvel[1]), (newvel[2]),
                    realspeed,
                    tmpvel[client][0], tmpvel[client][1],
                    (speeddir[0]), (speeddir[1]),
                    (maxspeed), (GetMaxSpeed(client)),
                    oldspeed,
                    proj,
                    wishdir[0], wishdir[1],
                    acc,
                    diff
                    );
        }

    }

    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newvel);

    // Speedmeter
    // if (showSpeed[client])
    //     PrintCenterText(client, "%f", speed);

    for (new i = 0; i < 2; i++)
        oldvel[client][i] = newvel[i];

    // Reset max speed
    // SetMaxSpeed(client, realMaxSpeeds[client]);
    SetMaxSpeed(client, GetMaxSpeed(client));
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

// Handles autohop and jumping while crouched
CheckJumping(client, buttons, Float:newvel[3])
{
    if (GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") == -1)
    {
        inair[client] = true;
    }
    else
    {
        // Pressing jump while landing?
        if (inair[client] && autohop[client] && buttons & IN_JUMP)
            newvel[2] = JUMP_SPEED;

        inair[client] = false;

        // Jumping while crouching
        if (duckjump && !jumpPressed[client] && buttons & IN_JUMP && buttons & IN_DUCK)
            newvel[2] = JUMP_SPEED;
    }

    // This needs to come after the jump checking in the block above, so
    // that this variable reflects the state of the last frame.
    // (Double negate to prevent tag mismatch warning)
    jumpPressed[client] = !!(buttons & IN_JUMP);
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
    SDKHook(client, SDKHook_PostThink, OnPostThink);
    SDKHook(client, SDKHook_PreThink, OnPreThink);
}

SetupClient(client)
{
    autohop[client] = defaultAutohop;
    showSpeed[client] = defaultSpeedo;
}

// 2D Vector functions {{{
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
