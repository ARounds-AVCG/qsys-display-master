--[[
================================================================================
  AVCG Display Master  —  Q-SYS Lua Control Script
  Ported from: AVCG-Display Master v0_1  (AMX / NetLinx)
  Original author : A.Rounds  —  AV Control Group
  Q-SYS port      : 2026-09-07

  Drop this entire file into a Q-SYS Control Script (or Text Controller)
  component. Create the controls listed in AVCG-Display-Master-README.md.
  Missing controls are ignored; the script will not throw.

  Supported families (from the original AMX DISPS[] table, plus PJLink):
    EPSON projector     network / serial
    LG LCD              network / serial
    Panasonic projector network
    Panasonic LCD       network
    Sony projector      network
    Sony LCD            network / serial
    NEC projector/LCD   network / serial
    NEC old LCD         network
    Barco projector     network
    Philips LCD         network (binary)
    PJLink generic      network

  Command surface (mirrors the AMX virtual device strings):
    POWER=1 / POWER=0 / POWER? / POWER=T
    INPUT=n / INPUT?
    VOLUME=n / VOLUME=UP / VOLUME=DOWN / VOLUME=DEFAULT / VOLUME?
    MUTE=0 / MUTE=1 / MUTE=T / MUTE?
    AV MUTE=0 / AV MUTE=1 / AV MUTE=T / AV MUTE?
    FREEZE=0 / FREEZE=1 / FREEZE=T / FREEZE?
    DISPLAY=<description>
    IP=x.x.x.x   IP PORT=n
    CONNECT / DISCONNECT / REINIT / SET BAUD
    PASSTHRU=<raw>
    POLLING=0|1   DEBUG=0|1
================================================================================
]]

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------
local VERSION       = "1.0.12"
local MODULE_NAME   = "AVCG-Display Master"

local PWR = { OFF = 0, ON = 1, WARMING = 2, COOLING = 3, FAIL = 4 }
local PWR_NAME = { [0] = "OFF", [1] = "ON", [2] = "WARMING", [3] = "COOLING", [4] = "FAIL" }

local MODE = { IP = "IP", SERIAL = "SERIAL" }
local CONN = { TEMP = "temporary", PERM = "permanent" }

local MAX_INPUTS    = 6
local MAX_QUEUE     = 100
local QUEUE_TICK    = 0.1          -- seconds (AMX TL_QUE was 110 ms)
local RX_TIMEOUT    = 3.0           -- seconds with no reply before retry
local MAX_RETRIES   = 3
local TEMP_HOLD     = 3.0           -- seconds after last TX before temp disconnect
local POLL_ON_S     = 10
local POLL_OFF_S    = 30
local POLL_WARM_S   = 3
local POLL_LAMP_S   = 61
local POLL_INPUT_S  = 3
local POLL_MUTE_S   = 5
local POLL_VOL_S    = 7
local POLL_AFTER_CMD_S = 2   -- confirm FB after a user set command

-- Wall clock. os.clock() is CPU time in some Lua builds and barely
-- advances in an idle script, which stalls polling and RX timeouts.
local function Now()
  return os.time()
end

--------------------------------------------------------------------------------
-- PROTOCOL DATABASE
-- Keys match the original DISPS[].DESCRIPTION strings so existing jobs
-- that send DISPLAY=EPSON:PROJECTOR:NETWORK keep working.
-- terminator  = string appended on TX
-- eol         = "cr" | "lf" | "crlf" | "none" | "any"
-- init        = bytes sent once on TCP connect (Epson ESC/VP.net etc.)
-- vol_fmt     = optional function(level) -> tx string
--------------------------------------------------------------------------------
local Protocols = {}

-- helpers used while building tables
local function copy(src)
  local dst = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = copy(v)
    else
      dst[k] = v
    end
  end
  return dst
end

--------------------------------------------------------------------------------
-- 1  EPSON GENERIC PROJECTOR  NETWORK
--------------------------------------------------------------------------------
Protocols["EPSON:PROJECTOR:NETWORK"] = {
  make = "EPSON", model = "GENERIC PROJECTOR",
  input_label = { "INPUT 1", "INPUT 2", "INPUT 3", "INPUT 4", "INPUT 5", "INPUT 6" },
  transport = MODE.IP, port = 3629, connect = CONN.TEMP,
  baud = 9600, terminator = "\r", eol = "cr",
  init = "ESC/VP.net\x10\x03\x00\x00\x00\x00",
  password = "",
  tx = {
    pwr_on      = "PWR ON",
    pwr_off     = "PWR OFF",
    input       = { "SOURCE 30", "SOURCE A0", "SOURCE 11", "SOURCE 21" },
    vol_up      = "VOL INC",
    vol_down    = "VOL DEC",
    vol_default = "VOL 100",
    vol         = "VOL ",
    amute_on    = "",
    amute_off   = "",
    vmute_on    = "MUTE ON",
    vmute_off   = "MUTE OFF",
    freeze_on   = "FREEZE ON",
    freeze_off  = "FREEZE OFF",
    q_pwr       = "PWR?",
    q_input     = "SOURCE?",
    q_vol       = "VOL?",
    q_amute     = "MUTE?",
    q_vmute     = "MUTE?",
    q_freeze    = "FREEZE?",
    q_lamp      = "LAMP?",
  },
  rx = {
    pwr_off     = { "PWR=00", "PWR=04", "PWR=05", "PWR=09" },
    pwr_on      = { "PWR=01" },
    pwr_cooling = { "PWR=03" },
    pwr_warming = { "PWR=02" },
    input       = { "SOURCE=30", "SOURCE=A0", "SOURCE=11", "SOURCE=21" },
    volume      = "VOL=",
    amute_off   = "MUTE=OFF",
    amute_on    = "MUTE=ON",
    vmute_off   = "MUTE=OFF",
    vmute_on    = "MUTE=ON",
    freeze_off  = "FREEZE=OFF",
    freeze_on   = "FREEZE=ON",
    ack         = ":",
    rxerror       = "ERR",
    pw_required = "\x10\x03\x00\x00\x41",
    pw_wrong    = "\x10\x03\x00\x00\x43",
    bad_request = "\x10\x03\x00\x00\x40",
  },
  vol_fmt = function(n)
    if n < 10 then return "VOL 0" .. tostring(n) end
    return "VOL " .. tostring(n)
  end,
}

--------------------------------------------------------------------------------
-- 2  EPSON GENERIC PROJECTOR  SERIAL
--------------------------------------------------------------------------------
Protocols["EPSON:PROJECTOR:SERIAL"] = copy(Protocols["EPSON:PROJECTOR:NETWORK"])
Protocols["EPSON:PROJECTOR:SERIAL"].transport = MODE.SERIAL
Protocols["EPSON:PROJECTOR:SERIAL"].init = ""
Protocols["EPSON:PROJECTOR:SERIAL"].port = 0

--------------------------------------------------------------------------------
-- 3  LG GENERIC LCD  NETWORK
--------------------------------------------------------------------------------
Protocols["LG:LCD:NETWORK"] = {
  make = "LG", model = "GENERIC LCD",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 9761, connect = CONN.TEMP,
  baud = 9600, terminator = "\r", eol = "cr",
  init = "",
  tx = {
    pwr_on      = "ka 01 01",
    pwr_off     = "ka 01 00",
    input       = { "xb 01 90", "xb 01 91", "xb 01 A6", "xb 01 80" },
    vol_up      = "mc 01 02",
    vol_down    = "mc 01 03",
    vol_default = "kf 01 32",
    vol         = "kf 01 ",
    amute_on    = "ke 01 01",
    amute_off   = "ke 01 00",
    vmute_on    = "kd 01 01",
    vmute_off   = "kd 01 00",
    freeze_on   = "",
    freeze_off  = "",
    q_pwr       = "ka 01 ff",
    q_input     = "xb 01 ff",
    q_vol       = "kf 01 ff",
    q_amute     = "ke 01 ff",
    q_vmute     = "kd 01 ff",
    q_freeze    = "",
    q_lamp      = "",
  },
  rx = {
    pwr_off     = { "a 01 OK00x", "A 01 OK00x", "a 01 NG00x", "A 01 NG00x" },
    pwr_on      = { "a 01 OK01x", "A 01 OK01x", "a 01 NG01x", "A 01 NG01x" },
    pwr_cooling = {},
    pwr_warming = {},
    input       = { "b 01 OK90", "b 01 OK91", "b 01 OKA6", "b 01 OK80" },
    volume      = "f 01 OK",
    amute_off   = "e 01 OK00",
    amute_on    = "e 01 OK01",
    vmute_off   = "d 01 OK00",
    vmute_on    = "d 01 OK01",
    freeze_off  = "",
    freeze_on   = "",
    ack         = "OK",
    rxerror       = "NG",
  },
  vol_fmt = function(n)
    -- LG volume is 0-64 hex on many sets; map 0-100 -> 0-64
    local hexv = math.floor((n / 100) * 64 + 0.5)
    if hexv < 0 then hexv = 0 end
    if hexv > 64 then hexv = 64 end
    return string.format("kf 01 %02X", hexv)
  end,
}

--------------------------------------------------------------------------------
-- 4  LG GENERIC LCD  SERIAL
--------------------------------------------------------------------------------
Protocols["LG:LCD:SERIAL"] = copy(Protocols["LG:LCD:NETWORK"])
Protocols["LG:LCD:SERIAL"].input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" }
Protocols["LG:LCD:SERIAL"].transport = MODE.SERIAL
Protocols["LG:LCD:SERIAL"].port = 0

--------------------------------------------------------------------------------
-- 5  PANASONIC GENERIC PROJECTOR  NETWORK
--------------------------------------------------------------------------------
Protocols["PANASONIC:PROJECTOR:NETWORK"] = {
  make = "PANASONIC", model = "GENERIC PROJECTOR",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 1024, connect = CONN.PERM,
  baud = 9600, terminator = "\r", eol = "cr",
  init = "",
  tx = {
    pwr_on      = "00PON",
    pwr_off     = "00POF",
    input       = { "00IIS:HD1", "00IIS:HD2", "00IIS:DL1", "00IIS:RG1" },
    vol_up      = "00AUU",
    vol_down    = "00AUD",
    vol_default = "00AVL:020",
    vol         = "00AVL:",
    amute_on    = "00AMT:1",
    amute_off   = "00AMT:0",
    vmute_on    = "00OSH:1",
    vmute_off   = "00OSH:0",
    freeze_on   = "00OFZ:1",
    freeze_off  = "00OFZ:0",
    q_pwr       = "00QPW",
    q_input     = "00QIN",
    q_vol       = "00QAV",
    q_amute     = "00QMT",
    q_vmute     = "00QSH",
    q_freeze    = "00QFZ",
    q_lamp      = "00Q$L",
  },
  rx = {
    pwr_off     = { "00000" },
    pwr_on      = { "00001" },
    pwr_cooling = {},
    pwr_warming = {},
    input       = { "HD1", "HD2", "DL1", "RG1" },
    volume      = "",
    amute_off   = "0",
    amute_on    = "1",
    vmute_off   = "0",
    vmute_on    = "1",
    freeze_off  = "0",
    freeze_on   = "1",
    ack         = "",
    rxerror       = "ER401",
  },
  vol_fmt = function(n)
    local v = math.floor((n / 100) * 63 + 0.5)
    return string.format("00AVL:%03d", v)
  end,
}

--------------------------------------------------------------------------------
-- 7  PANASONIC GENERIC LCD  NETWORK
--------------------------------------------------------------------------------
Protocols["PANASONIC:LCD:NETWORK"] = copy(Protocols["PANASONIC:PROJECTOR:NETWORK"])
Protocols["PANASONIC:LCD:NETWORK"].input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" }
Protocols["PANASONIC:LCD:NETWORK"].model = "GENERIC LCD"

--------------------------------------------------------------------------------
-- 9  SONY PROJECTOR  NETWORK  (ADCP / SDAP style ASCII, LF)
--------------------------------------------------------------------------------
Protocols["SONY:PROJECTOR:NETWORK"] = {
  make = "SONY", model = "GENERIC PROJECTOR",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 53595, connect = CONN.TEMP,
  baud = 38400, terminator = "\n", eol = "lf",
  init = "",
  tx = {
    pwr_on      = 'power "on"',
    pwr_off     = 'power "off"',
    input       = { 'input "hdmi1"', 'input "hdmi2"', 'input "hdmi3"', 'input "hdbaset1"' },
    vol_up      = "",
    vol_down    = "",
    vol_default = "",
    vol         = "",
    amute_on    = 'muting "on"',
    amute_off   = 'muting "off"',
    vmute_on    = 'blank "on"',
    vmute_off   = 'blank "off"',
    freeze_on   = 'freeze "on"',
    freeze_off  = 'freeze "off"',
    q_pwr       = "power_status ?",
    q_input     = "input ?",
    q_vol       = "",
    q_amute     = "muting ?",
    q_vmute     = "blank ?",
    q_freeze    = "freeze ?",
    q_lamp      = "timer ?",
  },
  rx = {
    pwr_off     = { "standby" },
    pwr_on      = { "on" },
    pwr_cooling = { "cooling" },
    pwr_warming = { "startup", "starup" }, -- original AMX had the typo; both kept
    input       = { "hdmi1", "hdmi2", "hdmi3", "hdbaset1" },
    volume      = "",
    amute_off   = "off",
    amute_on    = "on",
    vmute_off   = "off",
    vmute_on    = "on",
    freeze_off  = "off",
    freeze_on   = "on",
    ack         = "",
    rxerror       = "error",
  },
}

--------------------------------------------------------------------------------
-- 11  SONY LCD  NETWORK  (Simple IP *SC / *SE / *SA)
--------------------------------------------------------------------------------
Protocols["SONY:LCD:NETWORK"] = {
  make = "SONY", model = "GENERIC LCD",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 20060, connect = CONN.TEMP,
  baud = 9600, terminator = "\n", eol = "lf",
  init = "",
  tx = {
    pwr_on      = "*SCPOWR0000000000000001",
    pwr_off     = "*SCPOWR0000000000000000",
    input       = {
      "*SCINPT0000000100000001",
      "*SCINPT0000000100000002",
      "*SCINPT0000000100000003",
      "*SCINPT0000000100000004",
    },
    vol_up      = "*SCIRCC0000000000000030",
    vol_down    = "*SCIRCC0000000000000031",
    vol_default = "*SCVOLU0000000000000030",
    vol         = "*SCVOLU00000000000000",
    amute_on    = "*SCAMUT0000000000000001",
    amute_off   = "*SCAMUT0000000000000000",
    vmute_on    = "*SCPMUT0000000000000001",
    vmute_off   = "*SCPMUT0000000000000000",
    freeze_on   = "",
    freeze_off  = "",
    q_pwr       = "*SEPOWR################",
    q_input     = "*SEINPT################",
    q_vol       = "*SEVOLU################",
    q_amute     = "*SEAMUT################",
    q_vmute     = "*SEPMUT################",
    q_freeze    = "",
    q_lamp      = "",
  },
  rx = {
    pwr_off     = { "POWR0000000000000000" },
    pwr_on      = { "POWR0000000000000001" },
    pwr_cooling = {},
    pwr_warming = {},
    input       = {
      "INPT0000000100000001",
      "INPT0000000100000002",
      "INPT0000000100000003",
      "INPT0000000100000004",
    },
    volume      = "VOLU",
    amute_off   = "AMUT0000000000000000",
    amute_on    = "AMUT0000000000000001",
    vmute_off   = "PMUT0000000000000000",
    vmute_on    = "PMUT0000000000000001",
    freeze_off  = "",
    freeze_on   = "",
    ack         = "",
    rxerror       = "",
  },
  vol_fmt = function(n)
    return string.format("*SCVOLU00000000000000%02d", math.max(0, math.min(99, n)))
  end,
}

--------------------------------------------------------------------------------
-- 12  SONY LCD  SERIAL
--------------------------------------------------------------------------------
Protocols["SONY:LCD:SERIAL"] = copy(Protocols["SONY:LCD:NETWORK"])
Protocols["SONY:LCD:SERIAL"].input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" }
Protocols["SONY:LCD:SERIAL"].transport = MODE.SERIAL
Protocols["SONY:LCD:SERIAL"].port = 0

--------------------------------------------------------------------------------
-- 13  NEC PROJECTOR  NETWORK  (ASCII PJ-style on 7142)
--------------------------------------------------------------------------------
Protocols["NEC:PROJECTOR:NETWORK"] = {
  make = "NEC", model = "GENERIC PROJECTOR",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 7142, connect = CONN.TEMP,
  baud = 9600, terminator = "\r", eol = "cr",
  init = "",
  tx = {
    pwr_on      = "power on",
    pwr_off     = "power off",
    input       = { "input hdmi1", "input hdmi2", "input hdmi3", "input hdbaset", "input computer" },
    vol_up      = "volume ++1",
    vol_down    = "volume --1",
    vol_default = "volume 10",
    vol         = "volume ",
    amute_on    = "avmute on",
    amute_off   = "avmute off",
    vmute_on    = "avmute video on",
    vmute_off   = "avmute video off",
    freeze_on   = "freeze on",
    freeze_off  = "freeze off",
    q_pwr       = "power",
    q_input     = "input",
    q_vol       = "volume",
    q_amute     = "avmute audio",
    q_vmute     = "avmute",
    q_freeze    = "freeze",
    q_lamp      = "lamp",
  },
  rx = {
    pwr_off     = { "power off" },
    pwr_on      = { "power on" },
    pwr_cooling = { "power cooling" },
    pwr_warming = { "power warming" },
    input       = { "input hdmi1", "input hdmi2", "input hdmi3", "input hdbaset", "input computer" },
    volume      = "volume",
    amute_off   = "avmute off",
    amute_on    = "avmute on",
    vmute_off   = "avmute video off",
    vmute_on    = "avmute video on",
    freeze_off  = "freeze off",
    freeze_on   = "freeze on",
    ack         = ">ok",
    rxerror       = ">error",
  },
  vol_fmt = function(n) return "volume " .. tostring(n) end,
}

--------------------------------------------------------------------------------
-- 14 / 15 / 16  NEC SERIAL + LCD variants
--------------------------------------------------------------------------------
Protocols["NEC:PROJECTOR:SERIAL"] = copy(Protocols["NEC:PROJECTOR:NETWORK"])
Protocols["NEC:PROJECTOR:SERIAL"].input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" }
Protocols["NEC:PROJECTOR:SERIAL"].transport = MODE.SERIAL
Protocols["NEC:PROJECTOR:SERIAL"].port = 0

Protocols["NEC:LCD:NETWORK"] = copy(Protocols["NEC:PROJECTOR:NETWORK"])
Protocols["NEC:LCD:NETWORK"].input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" }
Protocols["NEC:LCD:NETWORK"].model = "GENERIC LCD"

Protocols["NEC:LCD:SERIAL"] = copy(Protocols["NEC:PROJECTOR:NETWORK"])
Protocols["NEC:LCD:SERIAL"].input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" }
Protocols["NEC:LCD:SERIAL"].model = "GENERIC LCD"
Protocols["NEC:LCD:SERIAL"].transport = MODE.SERIAL
Protocols["NEC:LCD:SERIAL"].port = 0

--------------------------------------------------------------------------------
-- 17  NEC OLD LCD  NETWORK  (short ASCII)
--------------------------------------------------------------------------------
Protocols["NEC:OLD LCD:NETWORK"] = {
  make = "NEC", model = "GENERIC OLD LCD",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 7142, connect = CONN.TEMP,
  baud = 9600, terminator = "\r", eol = "cr",
  init = "",
  tx = {
    pwr_on      = '00"',
    pwr_off     = "00!",
    input       = { "00_h1", "00_h2", "00_d1", "00_r1" },
    vol_up      = "",
    vol_down    = "",
    vol_default = "",
    vol         = "",
    amute_on    = "",
    amute_off   = "",
    vmute_on    = "",
    vmute_off   = "",
    freeze_on   = "",
    freeze_off  = "",
    q_pwr       = "00vP",
    q_input     = "00vI",
    q_vol       = "00vV",
    q_amute     = "",
    q_vmute     = "",
    q_freeze    = "",
    q_lamp      = "",
  },
  rx = {
    pwr_off     = { "00vP0" },
    pwr_on      = { "00vP1" },
    pwr_cooling = {},
    pwr_warming = {},
    input       = {},
    volume      = "",
    amute_off   = "",
    amute_on    = "",
    vmute_off   = "",
    vmute_on    = "",
    freeze_off  = "",
    freeze_on   = "",
    ack         = "",
    rxerror       = "",
  },
}

--------------------------------------------------------------------------------
-- 19  BARCO PROJECTOR  NETWORK  (telnet 3023)
--------------------------------------------------------------------------------
Protocols["BARCO:PROJECTOR:NETWORK"] = {
  make = "BARCO", model = "GENERIC PROJECTOR",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 3023, connect = CONN.TEMP,
  baud = 115200, terminator = "\r", eol = "cr",
  init = "",
  tx = {
    pwr_on      = "[POWR1]",
    pwr_off     = "[POWR0]",
    input       = { "[MSRC0]", "[MSRC1]", "[MSRC2]", "[MSRC5]", "[MSRC6]" },
    vol_up      = "",
    vol_down    = "",
    vol_default = "",
    vol         = "",
    amute_on    = "[AMUT1]",
    amute_off   = "[AMUT0]",
    vmute_on    = "[PMUT1]",
    vmute_off   = "[PMUT0]",
    freeze_on   = "[FRZE1]",
    freeze_off  = "[FRZE0]",
    q_pwr       = "[POWR?]",
    q_input     = "[MSRC?]",
    q_vol       = "",
    q_amute     = "[AMUT?]",
    q_vmute     = "[PMUT?]",
    q_freeze    = "[FRZE?]",
    q_lamp      = "",
  },
  rx = {
    pwr_off     = { "[POWR!00]" },
    pwr_on      = { "[POWR!01]" },
    pwr_cooling = {},
    pwr_warming = {},
    input       = { "[MSRC!00]", "[MSRC!01]", "[MSRC!02]", "[MSRC!05]", "[MSRC!06]" },
    volume      = "",
    amute_off   = "[AMUT!00]",
    amute_on    = "[AMUT!01]",
    vmute_off   = "[PMUT!00]",
    vmute_on    = "[PMUT!01]",
    freeze_off  = "[FRZE!00]",
    freeze_on   = "[FRZE!01]",
    ack         = "",
    rxerror       = "",
  },
}

--------------------------------------------------------------------------------
-- 21  PHILIPS LCD  NETWORK  (binary, no terminator)
--------------------------------------------------------------------------------
Protocols["PHILIPS:LCD:NETWORK"] = {
  make = "PHILIPS", model = "GENERIC LCD",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 5000, connect = CONN.TEMP,
  baud = 9600, terminator = "", eol = "none",
  init = "",
  binary = true,
  tx = {
    pwr_on      = "\x06\x01\x00\x18\x02\x1D",
    pwr_off     = "\x06\x01\x00\x18\x01\x1E",
    input       = {
      "\x09\x01\x00\xAC\x0D\x09\x01\x00\xA1",
      "\x09\x01\x00\xAC\x06\x09\x01\x00\xAA",
      "\x09\x01\x00\xAC\x0F\x09\x01\x00\xA3",
      "\x09\x01\x00\xAC\x19\x09\x01\x00\xB5",
    },
    vol_up      = "\x06\x01\x00\x41\x01\x47",
    vol_down    = "\x06\x01\x00\x41\x00\x46",
    vol_default = "\x06\x01\x00\x44\x00\x0A\x49",
    vol         = "",
    amute_on    = "\x06\x01\x00\x47\x01\x41",
    amute_off   = "\x06\x01\x00\x47\x00\x40",
    vmute_on    = "",
    vmute_off   = "",
    freeze_on   = "",
    freeze_off  = "",
    q_pwr       = "\x05\x01\x00\x19\x1D",
    q_input     = "\x05\x01\x00\xAD\xA9",
    q_vol       = "\x05\x01\x00\x45\x41",
    q_amute     = "\x05\x01\x00\x46\x42",
    q_vmute     = "",
    q_freeze    = "",
    q_lamp      = "",
  },
  rx = {
    pwr_off     = { "\x06\x01\x00\x19\x01\x1F", "\x06\x01\x01\x19\x01\x1E" },
    pwr_on      = { "\x06\x01\x00\x19\x02\x1C", "\x06\x01\x01\x19\x02\x1D" },
    pwr_cooling = {},
    pwr_warming = {},
    input       = {
      "\x09\x01\x00\xAD\x0D",
      "\x09\x01\x00\xAD\x06",
      "\x09\x01\x00\xAD\x0F",
      "\x09\x01\x00\xAD\x19",
    },
    volume      = "",
    amute_off   = "\x06\x01\x00\x46\x00\x41",
    amute_on    = "\x06\x01\x00\x46\x01\x40",
    vmute_off   = "",
    vmute_on    = "",
    freeze_off  = "",
    freeze_on   = "",
    ack         = "\x01\x00\x00\x06",
    rxerror       = "",
    bad_request = "\x01\x00\x00\x15",
  },
}

--------------------------------------------------------------------------------
-- 30  PJLINK GENERIC  NETWORK
--------------------------------------------------------------------------------
Protocols["PJLINK:GENERIC:NETWORK"] = {
  make = "PJLINK", model = "GENERIC PJLINK",
  input_label = { "HDMI 1", "HDMI 2", "HDMI 3", "HDBT", "NETWORK", "SDI" },
  transport = MODE.IP, port = 4352, connect = CONN.TEMP,
  baud = 9600, terminator = "\r", eol = "cr",
  init = "",
  pjlink = true,
  tx = {
    pwr_on      = "%1POWR 1",
    pwr_off     = "%1POWR 0",
    input       = { "%1INPT 21", "%1INPT 22", "%1INPT 23", "%1INPT 24", "%1INPT 11" },
    vol_up      = "",
    vol_down    = "",
    vol_default = "",
    vol         = "",
    amute_on    = "%1AVMT 21",
    amute_off   = "%1AVMT 20",
    vmute_on    = "%1AVMT 31",
    vmute_off   = "%1AVMT 30",
    freeze_on   = "%2FREZ 1",
    freeze_off  = "%2FREZ 0",
    q_pwr       = "%1POWR ?",
    q_input     = "%1INPT ?",
    q_vol       = "",
    q_amute     = "%1AVMT ?",
    q_vmute     = "%1AVMT ?",
    q_freeze    = "%2FREZ ?",
    q_lamp      = "%1LAMP ?",
  },
  rx = {
    pwr_off     = { "%1POWR=0" },
    pwr_on      = { "%1POWR=1" },
    pwr_cooling = { "%1POWR=2" },
    pwr_warming = { "%1POWR=3" },
    input       = { "%1INPT=21", "%1INPT=22", "%1INPT=23", "%1INPT=24", "%1INPT=11" },
    volume      = "",
    amute_off   = "%1AVMT=20",
    amute_on    = "%1AVMT=21",
    vmute_off   = "%1AVMT=30",
    vmute_on    = "%1AVMT=31",
    freeze_off  = "%2FREZ=0",
    freeze_on   = "%2FREZ=1",
    ack         = "OK",
    rxerror       = "ERR",
  },
}

--------------------------------------------------------------------------------
-- SORTED MODEL LIST (for combo box)
--------------------------------------------------------------------------------
local ModelList = {}
do
  for name, _ in pairs(Protocols) do
    table.insert(ModelList, name)
  end
  table.sort(ModelList)
end

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local Status = {
  pwr           = PWR.OFF,
  volume        = 0,
  amute         = false,
  vmute         = false,
  freeze        = false,
  input         = 0,
  input_str     = "",
  input_request = "",
  last_cmd      = "",
  lamp          = "",
  comms_ok      = false,
}

local Client = {
  address       = "",
  port          = 0,
  status        = "disconnected",   -- disconnected | connecting | connected
  connect_type  = CONN.TEMP,
}

local Display = nil                 -- current protocol table
local DisplayKey = ""
local Polling = true
local DebugOn = false
local SerialReady = false

local Queue = {
  items     = {},
  inflight  = false,
  sent      = "",
  retries   = 0,
  no_rx     = 0,
  fail_n    = 0,
}

local RxBuf = ""
local LastPollOn = 0
local LastPollOff = 0
local LastPollWarm = 0
local LastPollLamp = 0
local LastTxAt = os.time()
local SuppressUI = false
local ReadyToSend = true

--------------------------------------------------------------------------------
-- CONTROL ACCESSORS  (safe if a control was not created)
-- Count = 1  →  Controls.Name
-- Count ≥ 2  →  Controls.Name[1], Controls.Name[2], …   (NOT "Name 1")
--------------------------------------------------------------------------------
local function C(name)
  local ok, ctl = pcall(function() return Controls[name] end)
  if ok then return ctl end
  return nil
end

-- Array controls have numeric [1] and no EventHandler on the parent table
local function IsArray(c)
  return type(c) == "table" and c[1] ~= nil and c.EventHandler == nil
end

local function Elem(name, index)
  local c = C(name)
  if not c then return nil end
  if index then
    if IsArray(c) then return c[index] end
    if index == 1 then return c end
    return nil
  end
  return c
end

local function SetString(name, s, index)
  local el = Elem(name, index)
  if el and el.String ~= nil then el.String = tostring(s or "") end
end

local function SetBool(name, b, index)
  local el = Elem(name, index)
  if el and el.Boolean ~= nil then el.Boolean = not not b end
end

local function SetLegend(name, text, index)
  local el = Elem(name, index)
  if not el then return end
  pcall(function() el.Legend = string.upper(tostring(text or "")) end)
end

local function SetInvisible(name, hide, index)
  local el = Elem(name, index)
  if not el then return end
  pcall(function() el.IsInvisible = not not hide end)
end

local function ApplyInputButtons()
  for i = 1, MAX_INPUTS do
    local label = ""
    if Display and Display.input_label then
      label = Display.input_label[i] or ""
    end
    local cLbl = Elem("InputLabel", i)
    if cLbl and cLbl.String ~= nil then
      local prev = SuppressUI
      SuppressUI = true
      cLbl.String = label
      SuppressUI = prev
    end
    local shown = label
    if shown == "" then shown = "Input " .. i end
    SetLegend("Input", shown, i)
    SetLegend("Input" .. i, shown)
    SetLegend("InputFb", shown, i)
    SetLegend("InputLabel", shown, i)
    local hide = (label == "")
    SetInvisible("Input", hide, i)
    SetInvisible("Input" .. i, hide)
    SetInvisible("InputFb", hide, i)
    SetInvisible("InputLabel", hide, i)
  end
end

-- Hide a button only when that model's command string is empty.
local function TxFilled(key)
  if not Display or not Display.tx then return false end
  local s = Display.tx[key]
  return type(s) == "string" and s:match("%S") ~= nil
end

local function ApplyFeatureButtons()
  local showMute = TxFilled("amute_on") or TxFilled("amute_off")
  local showAv   = TxFilled("vmute_on") or TxFilled("vmute_off")
  local showFrz  = TxFilled("freeze_on") or TxFilled("freeze_off")
  SetInvisible("Mute",         not showMute)
  SetInvisible("MuteToggle",   not showMute)
  SetInvisible("MuteFb",       not showMute)
  SetInvisible("AVMute",       not showAv)
  SetInvisible("AVMuteToggle", not showAv)
  SetInvisible("AVMuteFb",     not showAv)
  SetInvisible("Freeze",       not showFrz)
  SetInvisible("FreezeToggle", not showFrz)
  SetInvisible("FreezeFb",     not showFrz)
end

local function SetValue(name, v, index)
  local el = Elem(name, index)
  if el and el.Value ~= nil then el.Value = tonumber(v) or 0 end
end

local function SetColor(name, color, index)
  local el = Elem(name, index)
  if el then el.Color = color end
end

-- Bind("Connect", fn)            -- single control, or every index of an array
-- Bind("Power", 2, fn)           -- one index of a Count≥2 control
-- fn(ctl, index)  index is 1 for singles
local function Bind(name, a, b)
  local index, fn
  if type(a) == "function" then
    fn, index = a, b
  else
    index, fn = a, b
  end
  if type(fn) ~= "function" then return end
  local c = C(name)
  if not c then return end

  if index then
    local el = Elem(name, index)
    if el then
      el.EventHandler = function(ctl) fn(ctl, index) end
    end
    return
  end

  if IsArray(c) then
    for i, el in ipairs(c) do
      el.EventHandler = function(ctl) fn(ctl, i) end
    end
  else
    c.EventHandler = function(ctl) fn(ctl, 1) end
  end
end

-- Momentary buttons fire EventHandler on press AND release. Only act on press.
local function Pressed(ctl)
  if SuppressUI then return false end
  if not ctl then return true end
  if ctl.Boolean ~= nil then return ctl.Boolean == true end
  if ctl.Value ~= nil then return ctl.Value ~= 0 end
  return true
end

-- Mute / AV Mute / Freeze also show state on the same button.
-- Once feedback has set Boolean true, the next press arrives as false
-- and Pressed() would drop it — so MUTE OFF never went out.
-- A momentary release follows the press within 0.35 s; ignore that edge.
local latchArm = {}
local function LatchedPress(ctl, key, isOn, onCmd, offCmd)
  if SuppressUI then return end
  if ctl and ctl.Boolean then
    latchArm[key] = true
    Timer.CallAfter(function() latchArm[key] = false end, 0.35)
    Control(isOn and offCmd or onCmd)
  elseif latchArm[key] then
    return
  elseif isOn then
    Control(offCmd)
  end
end

-- Real Epson needs ESC/VP.net. Crestron RMC3 Serial I/O farm: leave Handshake off.
local function HandshakeOn()
  local c = C("Handshake")
  if not c then return true end
  local el = IsArray(c) and c[1] or c
  if el.Boolean == nil then return true end
  return el.Boolean
end

--------------------------------------------------------------------------------
-- LOGGING
--------------------------------------------------------------------------------
local function HexDump(s)
  if not s or #s == 0 then return "" end
  if s:match("^[%g%s]*$") and not s:match("%c") then
    return s:gsub("\r", "<CR>"):gsub("\n", "<LF>")
  end
  local t = {}
  for i = 1, #s do
    t[#t + 1] = string.format("%02X", s:byte(i))
  end
  return table.concat(t, " ")
end

local function Notify(msg)
  print(string.format("[%s] %s", MODULE_NAME, msg))
  SetString("StatusText", msg)
  SetString("Status", msg)
  local log = C("EventLog")
  if log then
    local cur = log.String or ""
    if #cur > 4000 then cur = cur:sub(-3000) end
    log.String = cur .. os.date("%H:%M:%S ") .. msg .. "\n"
  end
end

local function Debug(msg)
  if DebugOn then
    print(string.format("[%s][DBG] %s", MODULE_NAME, msg))
    SetString("DebugText", msg)
  end
end

--------------------------------------------------------------------------------
-- FEEDBACK
--------------------------------------------------------------------------------
local function PushFeedback()
  SuppressUI = true
  -- Legacy single-LED names (still work if you keep them)
  SetBool("PowerOnFb",    Status.pwr == PWR.ON)
  SetBool("PowerOffFb",   Status.pwr == PWR.OFF)
  SetBool("WarmingFb",    Status.pwr == PWR.WARMING)
  SetBool("CoolingFb",    Status.pwr == PWR.COOLING)
  SetBool("PowerStateOn", Status.pwr == PWR.ON)
  SetString("PowerState", PWR_NAME[Status.pwr] or "?")

  -- Grouped PowerFb + Power buttons: [1] Off  [2] On  [3] Warming/Cooling
  local p_off  = Status.pwr == PWR.OFF
  local p_on   = Status.pwr == PWR.ON
  local p_wc   = Status.pwr == PWR.WARMING or Status.pwr == PWR.COOLING
  SetBool("PowerFb", p_off, 1)
  SetBool("PowerFb", p_on,  2)
  SetBool("PowerFb", p_wc,  3)
  SetBool("Power",   p_off, 1)
  SetBool("Power",   p_on,  2)
  SetBool("Power",   p_wc,  3)
  SetBool("PowerOff",    p_off)
  SetBool("PowerOn",     p_on)
  SetBool("PowerToggle", p_on or Status.pwr == PWR.WARMING)

  for i = 1, MAX_INPUTS do
    local on = (Status.input == i and Status.pwr == PWR.ON)
    SetBool("Input" .. i .. "Fb", on)
    SetBool("InputFb", on, i)
    SetBool("Input" .. i, on)
    SetBool("Input", on, i)
  end
  SetString("InputFb", Status.input > 0 and tostring(Status.input) or "")

  SetBool("MuteFb",       Status.amute)
  SetBool("AVMuteFb",     Status.vmute)
  SetBool("FreezeFb",     Status.freeze)
  SetBool("Mute",         Status.amute)
  SetBool("MuteToggle",   Status.amute)
  SetBool("AVMute",       Status.vmute)
  SetBool("AVMuteToggle", Status.vmute)
  SetBool("Freeze",       Status.freeze)
  SetBool("FreezeToggle", Status.freeze)
  -- Do not write Value onto Volume if it is a 3-button array
  if not IsArray(C("Volume")) then
    SetValue("Volume", Status.volume)
  end
  SetString("VolumeFb", tostring(Status.volume))
  SetString("LampHours", Status.lamp)

  SetBool("CommsOk",   Status.comms_ok)
  SetBool("CommsFail", not Status.comms_ok)
  SetColor("CommsOk",   Status.comms_ok and "green" or "gray")
  SetColor("CommsFail", Status.comms_ok and "gray"  or "red")

  if Display then
    SetString("MakeModel", Display.make .. " " .. Display.model)
  end

  local sock = C("ConnStatus")
  if sock then sock.String = Client.status end
  SuppressUI = false
end

--------------------------------------------------------------------------------
-- TRANSPORT
--------------------------------------------------------------------------------
local Tcp = TcpSocket.New()
Tcp.ReadTimeout      = 0
Tcp.WriteTimeout     = 0
Tcp.ReconnectTimeout = 0          -- we manage reconnect ourselves

local function SerialPort()
  if SerialPorts and SerialPorts[1] then return SerialPorts[1] end
  return nil
end

local function IsConnected()
  if not Display then return false end
  if Display.transport == MODE.SERIAL then
    local sp = SerialPort()
    return sp and sp.IsOpen
  end
  return Client.status == "connected"
end

local function SendRaw(payload)
  if not payload or payload == "" then return false end
  local term = (Display and Display.terminator) or ""
  local frame = payload .. term
  LastTxAt = Now()
  Status.last_cmd = payload
  SetString("TxLog", HexDump(frame))
  Debug("TX> " .. HexDump(frame))

  if Display.transport == MODE.SERIAL then
    local sp = SerialPort()
    if not sp or not sp.IsOpen then
      Notify("SERIAL PORT NOT OPEN")
      return false
    end
    sp:Write(frame)
    return true
  end

  if Client.status ~= "connected" then
    Debug("TX deferred — socket not connected")
    return false
  end
  Tcp:Write(frame)
  return true
end

local ConnectNow, DisconnectNow, ProcessQueue  -- forward decls

local function OpenSerial()
  local sp = SerialPort()
  if not sp then
    Notify("No SerialPorts[1] — enable a serial input on the Control Script and wire a Core serial port")
    return
  end
  local baud = 9600
  if Display and Display.baud then baud = Display.baud end
  local cBaud = C("Baud")
  if cBaud and tonumber(cBaud.String or cBaud.Value) then
    baud = tonumber(cBaud.String or cBaud.Value)
  end
  Debug("Opening serial " .. tostring(baud) .. ",N,8,1")
  sp:Open(baud, 8, "N", 1)
end

ConnectNow = function()
  if not Display then
    Notify("Select a display model first")
    return
  end
  if Display.transport == MODE.SERIAL then
    OpenSerial()
    return
  end
  if Client.address == "" or #Client.address < 7 then
    Notify("Set IP address first")
    return
  end
  if Client.status == "connected" or Client.status == "connecting" then return end
  Client.status = "connecting"
  PushFeedback()
  Debug("CONNECT " .. Client.address .. ":" .. tostring(Client.port))
  Tcp:Connect(Client.address, Client.port)
end

DisconnectNow = function()
  if Display and Display.transport == MODE.SERIAL then
    local sp = SerialPort()
    if sp and sp.IsOpen then sp:Close() end
    Client.status = "disconnected"
    PushFeedback()
    return
  end
  if Client.status ~= "disconnected" then
    Debug("DISCONNECT")
    Tcp:Disconnect()
  end
  Client.status = "disconnected"
  Queue.inflight = false
  PushFeedback()
end

--------------------------------------------------------------------------------
-- QUEUE
--------------------------------------------------------------------------------
local function IsQuery(cmd)
  if not Display or not cmd or cmd == "" then return false end
  local t = Display.tx
  return cmd == t.q_pwr or cmd == t.q_input or cmd == t.q_vol
      or cmd == t.q_amute or cmd == t.q_vmute or cmd == t.q_freeze or cmd == t.q_lamp
end

local function StripQueries()
  local keep = {}
  for _, c in ipairs(Queue.items) do
    if not IsQuery(c) then keep[#keep + 1] = c end
  end
  Queue.items = keep
end

-- urgent=true: user button. Drop waiting polls and insert at the front.
-- urgent=false: poll/query. Skip if a user command is already waiting.
local function Enqueue(cmd, urgent)
  if not cmd or cmd == "" then return end

  if urgent then
    StripQueries()
    table.insert(Queue.items, 1, cmd)
    LastPollOn   = Now()
    LastPollOff  = Now()
    LastPollWarm = Now()
    LastPollLamp = Now()
    Debug("QUE ! " .. cmd .. "  (" .. #Queue.items .. ")")
  else
    for _, c in ipairs(Queue.items) do
      if c == cmd then return end
      if not IsQuery(c) then return end
    end
    if #Queue.items >= MAX_QUEUE then table.remove(Queue.items, 1) end
    table.insert(Queue.items, cmd)
    Debug("QUE +" .. cmd .. "  (" .. #Queue.items .. ")")
  end

  if not Display then return end
  if Display.transport == MODE.IP and Client.status == "disconnected" then
    ConnectNow()
  else
    ProcessQueue()
  end
end

local function QueryAfter(qcmd, delay)
  -- Always queue the confirm query. Skipping while inflight is what made
  -- SOURCE 30 get retried instead of SOURCE? against the Crestron farm
  -- (set commands often have no ACK).
  Timer.CallAfter(function()
    if not Display then return end
    Control(qcmd)
  end, delay or POLL_AFTER_CMD_S)
end

ProcessQueue = function()
  if not ReadyToSend then return end
  if Queue.inflight then return end
  if #Queue.items == 0 then
    -- temp TCP sessions drop after the hold time
    if Display and Display.transport == MODE.IP
       and Display.connect == CONN.TEMP
       and Client.status == "connected"
       and (Now() - LastTxAt) > TEMP_HOLD then
      DisconnectNow()
    end
    return
  end
  if not IsConnected() then
    if Display and Display.transport == MODE.IP and Client.status == "disconnected" then
      ConnectNow()
    end
    return
  end

  local cmd = table.remove(Queue.items, 1)
  Queue.sent = cmd
  Queue.inflight = true
  Queue.retries = 0
  if not SendRaw(cmd) then
    Queue.inflight = false
    table.insert(Queue.items, 1, cmd)   -- put back
  end
end

local function ClearQueue()
  Queue.items = {}
  Queue.inflight = false
  Queue.retries = 0
  Queue.no_rx = 0
end

--------------------------------------------------------------------------------
-- RX PARSER
--------------------------------------------------------------------------------
local function Contains(hay, needle)
  if not needle or needle == "" then return false end
  return tostring(hay):find(needle, 1, true) ~= nil
end

local function AnyContains(hay, list)
  if type(list) ~= "table" then return Contains(hay, list) end
  for _, n in ipairs(list) do
    if n and n ~= "" and Contains(hay, n) then return true end
  end
  return false
end

local function HandleRx(raw)
  if not raw or raw == "" then return end
  Status.comms_ok = true
  Queue.inflight = false
  Queue.retries = 0
  Queue.no_rx = 0
  Queue.fail_n = 0
  SetString("RxLog", HexDump(raw))
  Debug("RX> " .. HexDump(raw))
  Notify("RX> " .. HexDump(raw))

  if not Display then return end
  local rx = Display.rx
  local last = Status.last_cmd

  -- PJLink handshake (unauthenticated "PJLINK 0" or auth "PJLINK 1 <rand>")
  if Display.pjlink and raw:find("PJLINK", 1, true) then
    if raw:find("PJLINK 1", 1, true) then
      Notify("PJLink authentication required — set Password control and reconnect")
      -- Best-effort MD5 if Crypto exists
      local pw = ""
      local cPw = C("Password")
      if cPw then pw = cPw.String or "" end
      local rand = raw:match("PJLINK 1%s+(%x+)")
      if rand and pw ~= "" and Crypto and Crypto.MD5 then
        local digest = Crypto.MD5(rand .. pw)
        -- next command in queue will go after digest prefix; PJLink wants
        -- the digest then the command. We just note it; subsequent cmds
        -- on this socket are accepted after a successful auth write.
        SendRaw(digest)
      end
    end
    -- PJLINK 0 = no auth, continue
    return
  end

  if rx.rxerror and rx.rxerror ~= "" and Contains(raw, rx.rxerror) then
    -- Projector rejected the command (:ERR, NG, ER401). Do not requeue it.
    -- Queue.retries used to be cleared at the top of HandleRx, so the old
    -- retry check was always true and SOURCE 11 looped until something else
    -- landed in the queue.
    local rejected = Queue.sent
    Queue.sent = ""
    Queue.inflight = false
    Notify("DEVICE ERROR" .. (rejected ~= "" and (" (" .. rejected .. ")") or ""))
    PushFeedback()
    ProcessQueue()
    return
  end

  if rx.pw_required and Contains(raw, rx.pw_required) then
    Notify("Unauthorized — password required")
    local pw = Display.password or ""
    local cPw = C("Password")
    if cPw and cPw.String ~= "" then pw = cPw.String end
    if pw ~= "" then Enqueue(pw) end
    PushFeedback()
    return
  end
  if rx.pw_wrong and Contains(raw, rx.pw_wrong) then
    Notify("Forbidden — password wrong")
    return
  end
  if rx.bad_request and Contains(raw, rx.bad_request) then
    Notify("Bad Request")
    return
  end

  -- Power
  if AnyContains(raw, rx.pwr_off) then
    Status.pwr = PWR.OFF
    Status.input = 0
    Status.input_str = ""
    Status.vmute = false
    Status.amute = false
    Notify("POWER=0")
  elseif AnyContains(raw, rx.pwr_on) then
    Status.pwr = PWR.ON
    Notify("POWER=1")
  elseif AnyContains(raw, rx.pwr_warming) then
    Status.pwr = PWR.WARMING
    Notify("POWER=2")
  elseif AnyContains(raw, rx.pwr_cooling) then
    Status.pwr = PWR.COOLING
    Notify("POWER=3")
  end

  -- Inputs
  if rx.input then
    for i, token in ipairs(rx.input) do
      if token and token ~= "" and Contains(raw, token) then
        Status.input = i
        Status.input_str = "INPUT=" .. i
        Notify(Status.input_str)
        break
      end
    end
  end

  -- Volume (query response)
  if Display.tx.q_vol ~= "" and last == Display.tx.q_vol then
    local num = raw:match("(%-?%d+)")
    if num then
      Status.volume = tonumber(num) or Status.volume
      Notify("VOLUME=" .. Status.volume)
      if Status.volume == 0 then
        Status.amute = true
        Notify("MUTE=1")
      end
    end
  end

  -- Audio mute
  if rx.amute_off ~= "" and Contains(raw, rx.amute_off) then
    Status.amute = false
    Notify("MUTE=0")
  elseif rx.amute_on ~= "" and Contains(raw, rx.amute_on) then
    Status.amute = true
    Notify("MUTE=1")
  end

  -- Video / shutter mute
  if rx.vmute_off ~= "" and Contains(raw, rx.vmute_off) then
    Status.vmute = false
    Notify("AV MUTE=0")
  elseif rx.vmute_on ~= "" and Contains(raw, rx.vmute_on) then
    Status.vmute = true
    Notify("AV MUTE=1")
  end

  -- Freeze
  if rx.freeze_off ~= "" and Contains(raw, rx.freeze_off) then
    Status.freeze = false
    Notify("FREEZE=0")
  elseif rx.freeze_on ~= "" and Contains(raw, rx.freeze_on) then
    Status.freeze = true
    Notify("FREEZE=1")
  end

  -- Lamp hours (best-effort numeric scrape)
  if Display.tx.q_lamp ~= "" and last == Display.tx.q_lamp then
    local hrs = raw:match("(%d+)")
    if hrs then
      Status.lamp = hrs
      Notify("LAMP=" .. hrs)
    end
  end

  -- Epson ACK colon while warming / cooling — kick a delayed query
  if rx.ack and rx.ack ~= "" and Contains(raw, rx.ack) then
    if Status.pwr == PWR.WARMING then
      Notify("POWER=2")
      Timer.CallAfter(function()
        Enqueue(Display.tx.q_pwr)
      end, 4)
    elseif Status.pwr == PWR.COOLING then
      Notify("POWER=3")
      Timer.CallAfter(function()
        Enqueue(Display.tx.q_pwr)
      end, 6)
    end
  end

  PushFeedback()
  ProcessQueue()
end

local function DrainText(sock_or_port, eol_enum, custom)
  if Display and Display.binary then
    local chunk = sock_or_port:Read(sock_or_port.BufferLength or 256)
    if chunk and #chunk > 0 then HandleRx(chunk) end
    return
  end
  local line
  if custom then
    line = sock_or_port:ReadLine(eol_enum, custom)
  else
    line = sock_or_port:ReadLine(eol_enum)
  end
  while line ~= nil do
    HandleRx(line)
    if custom then
      line = sock_or_port:ReadLine(eol_enum, custom)
    else
      line = sock_or_port:ReadLine(eol_enum)
    end
  end
end

local function EolFor(obj)
  -- obj is TcpSocket or SerialPorts
  local kind = (Display and Display.eol) or "any"
  local T = (obj == Tcp) and TcpSocket.EOL or SerialPorts.EOL
  if kind == "cr"   then return T.Custom, "\r" end
  if kind == "lf"   then return T.Lf end
  if kind == "crlf" then return T.CrLfStrict end
  if kind == "none" then return nil end
  return T.Any
end

--------------------------------------------------------------------------------
-- SOCKET / SERIAL EVENTS
--------------------------------------------------------------------------------
Tcp.EventHandler = function(sock, evt, err)
  if evt == TcpSocket.Events.Connected then
    Client.status = "connected"
    Status.comms_ok = true
    Notify("CONNECTED " .. Client.address .. ":" .. tostring(Client.port))
    PushFeedback()
    if Display and Display.init and Display.init ~= "" and HandshakeOn() then
      Debug("INIT handshake")
      ReadyToSend = false
      sock:Write(Display.init)
      -- Let the projector ACK ESC/VP.net before the first queued command
      -- (otherwise handshake + PWR ON land in one TCP packet).
      Timer.CallAfter(function()
        ReadyToSend = true
        ProcessQueue()
      end, 0.2)
    else
      ReadyToSend = true
      ProcessQueue()
    end

  elseif evt == TcpSocket.Events.Data then
    local e, custom = EolFor(Tcp)
    if not e then
      local chunk = sock:Read(sock.BufferLength)
      if chunk then HandleRx(chunk) end
    else
      DrainText(sock, e, custom)
    end

  elseif evt == TcpSocket.Events.Closed then
    Client.status = "disconnected"
    Queue.inflight = false
    Notify("SOCKET CLOSED BY REMOTE")
    PushFeedback()
    if Display and Display.connect == CONN.PERM then
      Timer.CallAfter(ConnectNow, 3)
    end

  elseif evt == TcpSocket.Events.Error then
    Client.status = "disconnected"
    Queue.inflight = false
    Status.comms_ok = false
    Notify("SOCKET ERROR: " .. tostring(err))
    PushFeedback()
    if Display and Display.connect == CONN.PERM then
      Timer.CallAfter(ConnectNow, 5)
    end

  elseif evt == TcpSocket.Events.Timeout then
    Client.status = "disconnected"
    Queue.inflight = false
    Notify("SOCKET TIMEOUT")
    PushFeedback()

  elseif evt == TcpSocket.Events.Reconnect then
    Client.status = "connecting"
    Debug("TCP reconnecting")
    PushFeedback()
  end
end

do
  local sp = SerialPort()
  if sp then
    sp.EventHandler = function(port, msg)
      if msg == SerialPorts.Events.Connected then
        SerialReady = true
        Client.status = "connected"
        Status.comms_ok = true
        Notify("SERIAL OPEN")
        PushFeedback()
        ProcessQueue()
      elseif msg == SerialPorts.Events.Data then
        local e, custom = EolFor(port)
        if not e then
          local chunk = port:Read(port.BufferLength)
          if chunk then HandleRx(chunk) end
        else
          DrainText(port, e, custom)
        end
      elseif msg == SerialPorts.Events.Closed or msg == SerialPorts.Events.Error then
        SerialReady = false
        Client.status = "disconnected"
        Status.comms_ok = false
        Queue.inflight = false
        Notify("SERIAL CLOSED / ERROR")
        PushFeedback()
      end
    end
  end
end

--------------------------------------------------------------------------------
-- HIGH-LEVEL COMMANDS  (same strings as the AMX virtual device)
--------------------------------------------------------------------------------
local function ApplyModel(key)
  local proto = Protocols[key]
  if not proto then
    Notify("COULD NOT FIND DISPLAY IN MEMORY: " .. tostring(key))
    return false
  end
  DisplayKey = key
  Display = proto
  Client.port = proto.port
  Client.connect_type = proto.connect
  SetString("Model", key)
  SetString("MakeModel", proto.make .. " " .. proto.model)
  SetValue("IPPort", proto.port)
  SetString("IPPort", tostring(proto.port))
  Notify("DISPLAY SET IS " .. key)
  Notify("DISPLAY MAKE = " .. proto.make)
  Notify("DISPLAY MODEL = " .. proto.model)

  -- open / re-init transport
  DisconnectNow()
  if proto.transport == MODE.SERIAL then
    Timer.CallAfter(function()
      OpenSerial()
      Timer.CallAfter(function() Control("REINIT") end, 1.0)
    end, 0.3)
  else
    Timer.CallAfter(function() Control("REINIT") end, 1.0)
  end
  ApplyInputButtons()
  ApplyFeatureButtons()
  PushFeedback()
  return true
end

local function Power(cmd)
  if not Display then return end
  if cmd == "POWER=1" then
    if Status.pwr == PWR.OFF or Status.pwr == PWR.FAIL then
      Status.pwr = PWR.WARMING
      Enqueue(Display.tx.pwr_on, true)
      Notify("POWER=2")
    elseif Status.pwr == PWR.COOLING then
      -- wait until off, then turn on
      Timer.CallAfter(function()
        if Status.pwr == PWR.OFF then Power("POWER=1") end
      end, 2.0)
    end
  elseif cmd == "POWER=0" then
    Status.pwr = PWR.COOLING
    Enqueue(Display.tx.pwr_off, true)
    Timer.CallAfter(function()
      if Display then Enqueue(Display.tx.pwr_off, true) end   -- AMX sent PWR OFF twice
    end, 1.0)
    Notify("POWER=3")
    Status.amute = false
    Status.vmute = false
    Status.freeze = false
    Status.input_str = ""
  end
  PushFeedback()
end

function Control(cmd)
  if not cmd or cmd == "" then return end
  Debug("CMD " .. cmd)

  if cmd == "POWER=1" or cmd == "POWER=0" then
    Power(cmd)
    return
  end
  if cmd == "POWER=T" then
    if Status.pwr == PWR.ON or Status.pwr == PWR.WARMING then
      Power("POWER=0")
    else
      Power("POWER=1")
    end
    return
  end
  if cmd == "POWER?" then
    if Display and Display.tx.q_pwr ~= "" then Enqueue(Display.tx.q_pwr) end
    return
  end

  if cmd:find("INPUT=", 1, true) == 1 then
    local n = tonumber(cmd:match("INPUT=(%d+)")) or 0
    if n >= 1 and n <= MAX_INPUTS and Display then
      local tx = Display.tx.input[n]
      if tx and tx ~= "" then
        Power("POWER=1")
        Status.input_request = tostring(n)
        -- send after the set is on, or immediately if already on
        local function sendInput()
          if Display then Enqueue(Display.tx.input[n], true) end
          QueryAfter("INPUT?", POLL_AFTER_CMD_S)
        end
        if Status.pwr == PWR.ON then
          sendInput()
        else
          Timer.CallAfter(function()
            if Status.pwr == PWR.ON then sendInput()
            else Timer.CallAfter(sendInput, 5.0) end
          end, 3.0)
        end
      end
    end
    return
  end
  if cmd == "INPUT?" then
    if Display and Display.tx.q_input ~= "" then Enqueue(Display.tx.q_input) end
    return
  end
  if cmd == "LAMP?" then
    if Display and Display.tx.q_lamp ~= "" then Enqueue(Display.tx.q_lamp) end
    return
  end

  if cmd:find("VOLUME=UP", 1, true) then
    if Display and Display.tx.vol_up ~= "" then Enqueue(Display.tx.vol_up, true) end
    Status.amute = false
    return
  end
  if cmd:find("VOLUME=DOWN", 1, true) then
    if Display and Display.tx.vol_down ~= "" then Enqueue(Display.tx.vol_down, true) end
    Status.amute = false
    return
  end
  if cmd:find("VOLUME=DEFAULT", 1, true) then
    if Display and Display.tx.vol_default ~= "" then Enqueue(Display.tx.vol_default, true) end
    Status.amute = false
    return
  end
  if cmd:find("VOLUME=", 1, true) == 1 then
    local n = tonumber(cmd:match("VOLUME=(%-?%d+)")) or 0
    Status.volume = n
    if Display then
      if Display.vol_fmt then
        Enqueue(Display.vol_fmt(n), true)
      elseif Display.tx.vol ~= "" then
        if n < 10 then Enqueue(Display.tx.vol .. "0" .. tostring(n), true)
        else Enqueue(Display.tx.vol .. tostring(n), true) end
      end
    end
    Status.amute = (n == 0)
    return
  end
  if cmd == "VOLUME?" then
    if Display and Display.tx.q_vol ~= "" then Enqueue(Display.tx.q_vol) end
    return
  end

  if cmd == "MUTE=0" then
    if Display then Enqueue(Display.tx.amute_off, true) end
    Status.amute = false
    Notify("MUTE=0")
    QueryAfter("MUTE?", POLL_AFTER_CMD_S)
    PushFeedback()
    return
  end
  if cmd == "MUTE=1" then
    if Display then Enqueue(Display.tx.amute_on, true) end
    Status.amute = true
    Notify("MUTE=1")
    QueryAfter("MUTE?", POLL_AFTER_CMD_S)
    PushFeedback()
    return
  end
  if cmd == "MUTE=T" then
    Control(Status.amute and "MUTE=0" or "MUTE=1")
    return
  end
  if cmd == "MUTE?" then
    if TxFilled("amute_on") or TxFilled("amute_off") then
      if Display.tx.q_amute ~= "" then Enqueue(Display.tx.q_amute) end
    end
    return
  end

  if cmd == "AV MUTE=1" then
    if Display then Enqueue(Display.tx.vmute_on, true) end
    Status.vmute = true
    Notify("AV MUTE=1")
    QueryAfter("AV MUTE?", POLL_AFTER_CMD_S)
    PushFeedback()
    return
  end
  if cmd == "AV MUTE=0" then
    if Display then Enqueue(Display.tx.vmute_off, true) end
    Status.vmute = false
    Notify("AV MUTE=0")
    QueryAfter("AV MUTE?", POLL_AFTER_CMD_S)
    PushFeedback()
    return
  end
  if cmd == "AV MUTE=T" then
    Control(Status.vmute and "AV MUTE=0" or "AV MUTE=1")
    return
  end
  if cmd == "AV MUTE?" then
    if (TxFilled("vmute_on") or TxFilled("vmute_off")) and Display.tx.q_vmute ~= "" then
      if Display.tx.q_vmute ~= Display.tx.q_amute or not (TxFilled("amute_on") or TxFilled("amute_off")) then
        Enqueue(Display.tx.q_vmute)
      end
    end
    return
  end

  if cmd == "FREEZE=0" then
    if Display then Enqueue(Display.tx.freeze_off, true) end
    Status.freeze = false
    Notify("FREEZE=0")
    QueryAfter("FREEZE?", POLL_AFTER_CMD_S)
    PushFeedback()
    return
  end
  if cmd == "FREEZE=1" then
    if Display then Enqueue(Display.tx.freeze_on, true) end
    Status.freeze = true
    Notify("FREEZE=1")
    QueryAfter("FREEZE?", POLL_AFTER_CMD_S)
    PushFeedback()
    return
  end
  if cmd == "FREEZE=T" then
    Control(Status.freeze and "FREEZE=0" or "FREEZE=1")
    return
  end
  if cmd == "FREEZE?" then
    if (TxFilled("freeze_on") or TxFilled("freeze_off")) and Display and Display.tx.q_freeze ~= "" then
      Enqueue(Display.tx.q_freeze)
    end
    return
  end

  if cmd:find("DISPLAY=", 1, true) == 1 then
    ApplyModel(cmd:sub(9))
    return
  end
  if cmd == "DISPLAY?" then
    if DisplayKey ~= "" then
      Notify("DISPLAY SET IS " .. DisplayKey)
    else
      Notify("COULD NOT FIND DISPLAY IN MEMORY")
    end
    return
  end

  if cmd:find("IP PORT=", 1, true) == 1 then
    Client.port = tonumber(cmd:sub(9)) or Client.port
    Notify("CLIENT.PORT=" .. tostring(Client.port))
    return
  end
  if cmd:find("IP=", 1, true) == 1 then
    local ip = cmd:sub(4)
    if #ip > 6 then
      Client.address = ip
      Notify("CLIENT.IP=" .. ip)
      if Display then Display.transport = MODE.IP end
    end
    return
  end
  if cmd:find("IP?", 1, true) then
    if #Client.address > 6 then Notify("IP=" .. Client.address)
    else Notify("IP ADDRESS HAS NOT BEEN DEFINED CORRECTLY") end
    return
  end

  if cmd == "CONNECT"    then ConnectNow()    return end
  if cmd == "DISCONNECT" then DisconnectNow() return end

  if cmd == "SET BAUD" then
    if Display and Display.transport == MODE.SERIAL then OpenSerial() end
    return
  end

  if cmd == "REINIT" then
    Control("POWER?")
    Timer.CallAfter(function() Control("INPUT?") end, 4.0)
    Timer.CallAfter(function() Control("MUTE?")  end, 5.0)
    return
  end

  if cmd:find("PASSTHRU=", 1, true) == 1 then
    Enqueue(cmd:sub(10), true)
    return
  end

  if cmd:find("POLLING=", 1, true) == 1 then
    Polling = (tonumber(cmd:sub(9)) or 0) ~= 0
    SuppressUI = true
    SetBool("PollingEnable", Polling)
    SuppressUI = false
    if Polling then
      LastPollOn, LastPollOff, LastPollWarm, LastPollLamp = 0, 0, 0, 0
      Tick:Start(QUEUE_TICK)
    end
    Notify("POLLING=" .. (Polling and "1" or "0"))
    return
  end
  if cmd:find("DEBUG=", 1, true) == 1 then
    DebugOn = (tonumber(cmd:sub(7)) or 0) ~= 0
    SetBool("DebugEnable", DebugOn)
    Debug("DEBUG=" .. (DebugOn and "1" or "0"))
    return
  end

  Notify("UNKNOWN COMMAND: " .. cmd)
end

--------------------------------------------------------------------------------
-- POLLING + QUEUE TICK
--------------------------------------------------------------------------------
-- Q-SYS GC's local Timer objects after ~20 ticks. Keep Tick global.
Tick = Timer.New()
Tick.EventHandler = function()
  local ok, err = pcall(function()
    ProcessQueue()

    -- inflight timeout / retry
    if Queue.inflight and (Now() - LastTxAt) > RX_TIMEOUT then
      Queue.inflight = false
      if IsQuery(Queue.sent) then
        Queue.no_rx = Queue.no_rx + 1
        if Queue.no_rx > 3 then
          Queue.no_rx = 0
          Status.comms_ok = false
          Notify("COMM FAIL")
          Queue.fail_n = Queue.fail_n + 1
          ClearQueue()
          PushFeedback()
        elseif Queue.sent ~= "" then
          Enqueue(Queue.sent)
        end
      else
        -- Sets (SOURCE 30, PWR ON, …) often get no reply on the RMC3 farm.
        -- Do not retry the set; drain the next item (usually SOURCE?).
        Debug("no ACK for set " .. tostring(Queue.sent))
        ProcessQueue()
      end
    end

    if not Polling or not Display then return end
    if Queue.inflight or #Queue.items > 0 then return end
    local now = Now()

    if Status.pwr == PWR.WARMING or Status.pwr == PWR.COOLING then
      if now - LastPollWarm >= POLL_WARM_S then
        LastPollWarm = now
        Control("POWER?")
      end
    elseif Status.pwr == PWR.ON then
      if now - LastPollOn >= POLL_ON_S then
        LastPollOn = now
        Control("POWER?")
        -- Delayed queries: skip if a user command landed in the meantime.
        Timer.CallAfter(function()
          if Polling and Status.pwr == PWR.ON and not Queue.inflight and #Queue.items == 0 then
            Control("INPUT?")
          end
        end, POLL_INPUT_S)
        Timer.CallAfter(function()
          if Polling and Status.pwr == PWR.ON and not Queue.inflight and #Queue.items == 0 then
            Control("AV MUTE?")
          end
        end, POLL_MUTE_S)
        Timer.CallAfter(function()
          if Polling and Status.pwr == PWR.ON and not Queue.inflight and #Queue.items == 0 then
            Control("VOLUME?")
          end
        end, POLL_VOL_S)
      end
      if now - LastPollLamp >= POLL_LAMP_S then
        LastPollLamp = now
        Control("LAMP?")
      end
    elseif Status.pwr == PWR.OFF then
      if now - LastPollOff >= POLL_OFF_S then
        LastPollOff = now
        Control("POWER?")
      end
    end
  end)
  if not ok then Notify("TICK ERR " .. tostring(err)) end
end

--------------------------------------------------------------------------------
-- BIND UI CONTROLS
--------------------------------------------------------------------------------
local function BindUI()
  SetLegend("Power", "Off", 1)
  SetLegend("Power", "On", 2)
  SetLegend("Power", "Toggle", 3)
  SetLegend("PowerOff", "Off")
  SetLegend("PowerOn", "On")
  SetLegend("PowerToggle", "Toggle")
  SetLegend("PowerFb", "Off", 1)
  SetLegend("PowerFb", "On", 2)
  SetLegend("PowerFb", "Warm/Cool", 3)

  ApplyInputButtons()
  ApplyFeatureButtons()

  SetLegend("Volume", "Up", 1)
  SetLegend("Volume", "Down", 2)
  SetLegend("Volume", "Default", 3)
  SetLegend("VolumeUp", "Vol +")
  SetLegend("VolumeDown", "Vol -")
  SetLegend("VolumeDefault", "Vol Def")

  SetLegend("Mute", "Mute")
  SetLegend("MuteToggle", "Mute")
  SetLegend("AVMute", "AV Mute")
  SetLegend("AVMuteToggle", "AV Mute")
  SetLegend("Freeze", "Freeze")
  SetLegend("FreezeToggle", "Freeze")

  SetLegend("Connect", "Connect")
  SetLegend("Disconnect", "Disconnect")
  SetLegend("Reinit", "Reinit")
  SetLegend("PollingEnable", "Polling")
  SetLegend("DebugEnable", "Debug")
  SetLegend("Handshake", "Handshake")
  SetLegend("SendCommand", "Send")
  SetLegend("SendPassthru", "Passthru")

  -- Model combo
  local m = C("Model")
  if m then
    m.Choices = ModelList
    m.EventHandler = function(ctl)
      if SuppressUI then return end
      if ctl.String and ctl.String ~= "" and ctl.String ~= DisplayKey then
        ApplyModel(ctl.String)
      end
    end
  end

  Bind("IPAddress", function(ctl)
    Control("IP=" .. (ctl.String or ""))
  end)
  Bind("IPPort", function(ctl)
    local p = tonumber(ctl.String or ctl.Value)
    if p then Control("IP PORT=" .. tostring(p)) end
  end)
  Bind("Connect",     function(ctl) if Pressed(ctl) then Control("CONNECT") end end)
  Bind("Disconnect",  function(ctl) if Pressed(ctl) then Control("DISCONNECT") end end)
  Bind("Reinit",      function(ctl) if Pressed(ctl) then Control("REINIT") end end)

  -- Grouped Power (Count=3): [1] Off  [2] On  [3] Toggle
  -- Momentary: EventHandler runs on press and release — ignore release.
  Bind("Power", 1, function(ctl) if Pressed(ctl) then Control("POWER=0") end end)
  Bind("Power", 2, function(ctl) if Pressed(ctl) then Control("POWER=1") end end)
  Bind("Power", 3, function(ctl) if Pressed(ctl) then Control("POWER=T") end end)
  Bind("PowerOn",     function(ctl) if Pressed(ctl) then Control("POWER=1") end end)
  Bind("PowerOff",    function(ctl) if Pressed(ctl) then Control("POWER=0") end end)
  Bind("PowerToggle", function(ctl) if Pressed(ctl) then Control("POWER=T") end end)

  -- Grouped Input (Count=6)  plus legacy Input1…Input6
  Bind("Input", function(ctl, i)
    if Pressed(ctl) then Control("INPUT=" .. i) end
  end)
  for i = 1, MAX_INPUTS do
    Bind("Input" .. i, function(ctl) if Pressed(ctl) then Control("INPUT=" .. i) end end)
  end
  Bind("InputLabel", function(ctl, i)
    if SuppressUI then return end
    if not Display then return end
    Display.input_label = Display.input_label or {}
    Display.input_label[i] = ctl.String or ""
    local label = Display.input_label[i]
    local shown = (label ~= "" and label) or ("Input " .. i)
    SetLegend("Input", shown, i)
    SetLegend("Input" .. i, shown)
    SetLegend("InputFb", shown, i)
    local hide = (label == "")
    SetInvisible("Input", hide, i)
    SetInvisible("Input" .. i, hide)
    SetInvisible("InputFb", hide, i)
    SetInvisible("InputLabel", hide, i)
  end)

  -- Grouped Volume (Count=3): [1] Up  [2] Down  [3] Default
  -- If Volume is still a single knob (Count=1), the else path sets a level.
  Bind("Volume", function(ctl, i)
    if IsArray(C("Volume")) then
      if not Pressed(ctl) then return end
      local cmds = { "VOLUME=UP", "VOLUME=DOWN", "VOLUME=DEFAULT" }
      if cmds[i] then Control(cmds[i]) end
    else
      if SuppressUI then return end
      Control("VOLUME=" .. tostring(math.floor((ctl.Value or 0) + 0.5)))
    end
  end)
  Bind("VolumeUp",      function(ctl) if Pressed(ctl) then Control("VOLUME=UP") end end)
  Bind("VolumeDown",    function(ctl) if Pressed(ctl) then Control("VOLUME=DOWN") end end)
  Bind("VolumeDefault", function(ctl) if Pressed(ctl) then Control("VOLUME=DEFAULT") end end)

  Bind("Mute", function(ctl)
    LatchedPress(ctl, "mute", Status.amute, "MUTE=1", "MUTE=0")
  end)
  Bind("MuteToggle", function(ctl) if Pressed(ctl) then Control("MUTE=T") end end)
  Bind("AVMute", function(ctl)
    LatchedPress(ctl, "av", Status.vmute, "AV MUTE=1", "AV MUTE=0")
  end)
  Bind("AVMuteToggle", function(ctl) if Pressed(ctl) then Control("AV MUTE=T") end end)
  Bind("Freeze", function(ctl)
    LatchedPress(ctl, "freeze", Status.freeze, "FREEZE=1", "FREEZE=0")
  end)
  Bind("FreezeToggle", function(ctl) if Pressed(ctl) then Control("FREEZE=T") end end)

  Bind("PollingEnable", function(ctl)
    if SuppressUI then return end
    Control("POLLING=" .. (ctl.Boolean and "1" or "0"))
  end)
  Bind("DebugEnable", function(ctl)
    Control("DEBUG=" .. (ctl.Boolean and "1" or "0"))
  end)
  Bind("Handshake", function()
    if SuppressUI then return end
    Notify("HANDSHAKE=" .. (HandshakeOn() and "1" or "0"))
  end)

  Bind("SendPassthru", function(ctl)
    if not Pressed(ctl) then return end
    local t = C("Passthru")
    if t and t.String ~= "" then Control("PASSTHRU=" .. t.String) end
  end)

  -- raw command box, same language as the AMX virtual device
  Bind("Command", function(ctl)
    if ctl.String and ctl.String ~= "" then
      Control(ctl.String)
      ctl.String = ""
    end
  end)
  Bind("SendCommand", function(ctl)
    if not Pressed(ctl) then return end
    local t = C("Command")
    if t and t.String ~= "" then
      Control(t.String)
      t.String = ""
    end
  end)
end

--------------------------------------------------------------------------------
-- STARTUP
--------------------------------------------------------------------------------
BindUI()

SetString("ModuleInfo", MODULE_NAME .. "  v" .. VERSION)
SetBool("PollingEnable", Polling)
SetBool("DebugEnable", DebugOn)
PushFeedback()

Tick:Start(QUEUE_TICK)

Notify(MODULE_NAME .. " v" .. VERSION .. " started  (" .. tostring(#ModelList) .. " protocols)")

-- If the design already has an IP / model saved in the controls, pick them up
do
  local ip = C("IPAddress")
  if ip and ip.String and #ip.String > 6 then
    Client.address = ip.String
  end
  local port = C("IPPort")
  if port then
    local p = tonumber(port.String or port.Value)
    if p and p > 0 then Client.port = p end
  end
  local model = C("Model")
  if model and model.String and Protocols[model.String] then
    ApplyModel(model.String)
  end
end
