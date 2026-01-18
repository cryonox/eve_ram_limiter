; EVE RAM Trimmer - AutoHotkey v2
; Trims working sets of EVE Online processes and optionally clears standby list
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ============== Configuration ==============
global Config := {
    IntervalMs: 2000,
    StandbyThresholdMB: 3000,
    FreeMemoryThresholdMB: 0,
    IntervalOptions: [500, 1000, 2000, 5000],
    StandbyThresholdOptions: [0, 2000, 4000, 8000],
    FreeMemoryThresholdOptions: [0, 1000, 2000, 4000, 8000],
    IgnoreList: []
}

; ============== State ==============
global State := {
    Running: true,
    Paused: false,
    EveTotal: 0,
    EveTrimmed: 0,
    LastStandbyCleared: false
}

; ============== Windows API Constants ==============
global PROCESS_ALL_ACCESS := 0x1F0FFF
global TOKEN_ADJUST_PRIVILEGES := 0x0020
global TOKEN_QUERY := 0x0008
global SE_PRIVILEGE_ENABLED := 0x00000002
global SystemMemoryListInformation := 0x50
global MemoryPurgeStandbyList := 4

; ============== Load Config ==============
LoadConfig() {
    configFile := A_ScriptDir "\config.json"
    if !FileExist(configFile)
        return
    
    content := FileRead(configFile)
    
    ; Simple JSON parsing for our specific format
    if RegExMatch(content, '"interval_ms"\s*:\s*(\d+)', &m)
        Config.IntervalMs := Integer(m[1])
    if RegExMatch(content, '"standby_threshold_mb"\s*:\s*(\d+)', &m)
        Config.StandbyThresholdMB := Integer(m[1])
    if RegExMatch(content, '"free_memory_threshold_mb"\s*:\s*(\d+)', &m)
        Config.FreeMemoryThresholdMB := Integer(m[1])
    
    ; Parse threshold options arrays
    if RegExMatch(content, '"interval_options"\s*:\s*\[([^\]]+)\]', &m)
        Config.IntervalOptions := ParseNumberArray(m[1])
    if RegExMatch(content, '"standby_threshold_options"\s*:\s*\[([^\]]+)\]', &m)
        Config.StandbyThresholdOptions := ParseNumberArray(m[1])
    if RegExMatch(content, '"free_memory_threshold_options"\s*:\s*\[([^\]]+)\]', &m)
        Config.FreeMemoryThresholdOptions := ParseNumberArray(m[1])
    
    ; Parse ignore_list array
    if RegExMatch(content, '"ignore_list"\s*:\s*\[(.*?)\]', &m) {
        listStr := m[1]
        if listStr != "" {
            Config.IgnoreList := StrSplit(listStr, ",")
            for i, name in Config.IgnoreList
                Config.IgnoreList[i] := Trim(name, ' `"')
        }
    }
    
    ; Ensure defaults are in option lists
    Config.IntervalOptions := EnsureInOptions(Config.IntervalOptions, Config.IntervalMs)
    Config.StandbyThresholdOptions := EnsureInOptions(Config.StandbyThresholdOptions, Config.StandbyThresholdMB)
    Config.FreeMemoryThresholdOptions := EnsureInOptions(Config.FreeMemoryThresholdOptions, Config.FreeMemoryThresholdMB)
}

ParseNumberArray(str) {
    arr := []
    for item in StrSplit(str, ",")
        arr.Push(Integer(Trim(item)))
    return arr
}

EnsureInOptions(options, value) {
    for opt in options
        if opt == value
            return options
    ; Insert in sorted order
    for i, opt in options {
        if value < opt {
            options.InsertAt(i, value)
            return options
        }
    }
    options.Push(value)
    return options
}

; ============== Memory Functions ==============
GetFreeMemoryMB() {
    static MEMORYSTATUSEX_SIZE := 64
    buf := Buffer(MEMORYSTATUSEX_SIZE, 0)
    NumPut("UInt", MEMORYSTATUSEX_SIZE, buf, 0)
    DllCall("GlobalMemoryStatusEx", "Ptr", buf)
    availPhys := NumGet(buf, 16, "UInt64")
    return Round(availPhys / (1024 * 1024))
}

GetTotalMemoryMB() {
    static MEMORYSTATUSEX_SIZE := 64
    buf := Buffer(MEMORYSTATUSEX_SIZE, 0)
    NumPut("UInt", MEMORYSTATUSEX_SIZE, buf, 0)
    DllCall("GlobalMemoryStatusEx", "Ptr", buf)
    totalPhys := NumGet(buf, 8, "UInt64")
    return Round(totalPhys / (1024 * 1024))
}

GetStandbyListMB() {
    ; Get accurate standby list size using the three standby cache components
    ; (Core + Normal Priority + Reserve) - matches the Python PDH implementation
    try {
        for item in ComObjGet("winmgmts:").ExecQuery("SELECT StandbyCacheCoreBytes, StandbyCacheNormalPriorityBytes, StandbyCacheReserveBytes FROM Win32_PerfFormattedData_PerfOS_Memory") {
            standbyCore := item.StandbyCacheCoreBytes
            standbyNormal := item.StandbyCacheNormalPriorityBytes
            standbyReserve := item.StandbyCacheReserveBytes
            totalStandby := standbyCore + standbyNormal + standbyReserve
            return Round(totalStandby / (1024 * 1024))
        }
    }
    
    return 0
}


; ============== Privilege Functions ==============
IsAdmin() {
    return DllCall("Shell32\IsUserAnAdmin")
}

EnablePrivilege(privilegeName) {
    hToken := 0
    hProcess := DllCall("GetCurrentProcess")
    
    if !DllCall("Advapi32\OpenProcessToken", "Ptr", hProcess, 
                "UInt", TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, "Ptr*", &hToken)
        return false
    
    ; LUID structure (8 bytes)
    luid := Buffer(8, 0)
    if !DllCall("Advapi32\LookupPrivilegeValueW", "Ptr", 0, "Str", privilegeName, "Ptr", luid) {
        DllCall("CloseHandle", "Ptr", hToken)
        return false
    }
    
    ; TOKEN_PRIVILEGES structure
    tp := Buffer(16, 0)
    NumPut("UInt", 1, tp, 0)  ; PrivilegeCount
    NumPut("UInt64", NumGet(luid, 0, "UInt64"), tp, 4)  ; LUID
    NumPut("UInt", SE_PRIVILEGE_ENABLED, tp, 12)  ; Attributes
    
    result := DllCall("Advapi32\AdjustTokenPrivileges", "Ptr", hToken, "Int", 0,
                      "Ptr", tp, "UInt", 16, "Ptr", 0, "Ptr", 0)
    
    lastErr := A_LastError
    DllCall("CloseHandle", "Ptr", hToken)
    
    return result && lastErr != 1300  ; ERROR_NOT_ALL_ASSIGNED
}

ClearStandbyList() {
    if !EnablePrivilege("SeProfileSingleProcessPrivilege")
        return false
    
    command := Buffer(4, 0)
    NumPut("UInt", MemoryPurgeStandbyList, command, 0)
    
    status := DllCall("ntdll\NtSetSystemInformation", "UInt", SystemMemoryListInformation,
                      "Ptr", command, "UInt", 4, "Int")
    
    return status == 0
}

; ============== Process Functions ==============
GetWindowTitleByPID(pid) {
    title := ""
    callback := CallbackCreate(EnumWindowsProc)
    DllCall("EnumWindows", "Ptr", callback, "Ptr", ObjPtr({pid: pid, title: &title}))
    CallbackFree(callback)
    return title
}

EnumWindowsProc(hwnd, lParam) {
    obj := ObjFromPtrAddRef(lParam)
    
    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return true
    
    windowPid := 0
    DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &windowPid)
    
    if windowPid == obj.pid {
        titleLen := DllCall("GetWindowTextLengthW", "Ptr", hwnd) + 1
        if titleLen > 1 {
            titleBuf := Buffer(titleLen * 2)
            DllCall("GetWindowTextW", "Ptr", hwnd, "Ptr", titleBuf, "Int", titleLen)
            %obj.title% := StrGet(titleBuf)
            return false  ; Stop enumeration
        }
    }
    return true
}

IsIgnoredCharacter(windowTitle, ignoreList) {
    if ignoreList.Length == 0
        return false
    
    ; Extract character name from "EVE - CharacterName" format
    charName := windowTitle
    if RegExMatch(windowTitle, "EVE - (.+)", &m)
        charName := m[1]
    
    charNameLower := StrLower(charName)
    for ignoreName in ignoreList {
        if charNameLower == StrLower(ignoreName)
            return true
    }
    return false
}

TrimProcessWorkingSet(pid) {
    hProcess := DllCall("OpenProcess", "UInt", PROCESS_ALL_ACCESS, "Int", 0, "UInt", pid, "Ptr")
    if !hProcess
        return false
    
    ; Use -1, -1 to trim without setting hard limits
    result := DllCall("SetProcessWorkingSetSize", "Ptr", hProcess, "Ptr", -1, "Ptr", -1)
    DllCall("CloseHandle", "Ptr", hProcess)
    return result
}

TrimEveWorkingSets() {
    global State
    eveTotal := 0
    eveTrimmed := 0
    
    for proc in ComObjGet("winmgmts:").ExecQuery("SELECT ProcessId, Name FROM Win32_Process WHERE Name LIKE '%exefile%'") {
        eveTotal++
        pid := proc.ProcessId
        windowTitle := GetWindowTitleByPID(pid)
        
        if IsIgnoredCharacter(windowTitle, Config.IgnoreList)
            continue
        
        if TrimProcessWorkingSet(pid)
            eveTrimmed++
    }
    
    State.EveTotal := eveTotal
    State.EveTrimmed := eveTrimmed
}

TrimAllWorkingSets() {
    trimmed := 0
    myPid := DllCall("GetCurrentProcessId")
    
    for proc in ComObjGet("winmgmts:").ExecQuery("SELECT ProcessId FROM Win32_Process") {
        pid := proc.ProcessId
        if pid == myPid || pid == 0 || pid == 4  ; Skip self, System Idle, System
            continue
        if TrimProcessWorkingSet(pid)
            trimmed++
    }
    
    return trimmed
}

TrimAllWorkingSetsManual(*) {
    trimmed := TrimAllWorkingSets()
    TrayTip("Trimmed " trimmed " processes", "EVE RAM Trimmer", 1)  ; 1 = Info icon
    UpdateTrayTip()
}


; ============== Main Loop ==============
TrimLoop() {
    if State.Paused
        return
    
    TrimEveWorkingSets()
    
    ; Check standby list clearing conditions
    if Config.StandbyThresholdMB > 0 || Config.FreeMemoryThresholdMB > 0 {
        standbyMB := GetStandbyListMB()
        freeMB := GetFreeMemoryMB()
        
        standbyExceeded := Config.StandbyThresholdMB > 0 && standbyMB > Config.StandbyThresholdMB
        freeLow := Config.FreeMemoryThresholdMB == 0 || freeMB < Config.FreeMemoryThresholdMB
        
        if standbyExceeded && freeLow
            State.LastStandbyCleared := ClearStandbyList()
    }
    
    UpdateTrayTip()
}

; ============== Tray Menu ==============
global StatusMenuItem := "Status: Initializing..."
global IntervalMenu := Menu()
global StandbyMenu := Menu()
global FreeMemMenu := Menu()

BuildTrayMenu() {
    A_TrayMenu.Delete()
    
    ; Add status line (will be updated dynamically)
    A_TrayMenu.Add(StatusMenuItem, (*) => 0)
    A_TrayMenu.Disable(StatusMenuItem)
    A_TrayMenu.Add()
    
    A_TrayMenu.Add("Pause", TogglePause)
    A_TrayMenu.Add("Trim All Processes", TrimAllWorkingSetsManual)
    A_TrayMenu.Add()
    
    ; Interval submenu (build once)
    IntervalMenu := Menu()
    for ms in Config.IntervalOptions {
        IntervalMenu.Add(ms "ms", SetInterval.Bind(ms))
        if ms == Config.IntervalMs
            IntervalMenu.Check(ms "ms")
    }
    A_TrayMenu.Add("Interval", IntervalMenu)
    
    ; Standby threshold submenu (build once)
    StandbyMenu := Menu()
    for mb in Config.StandbyThresholdOptions {
        label := mb == 0 ? "Disabled" : mb " MB"
        StandbyMenu.Add(label, SetStandbyThreshold.Bind(mb))
        if mb == Config.StandbyThresholdMB
            StandbyMenu.Check(label)
    }
    A_TrayMenu.Add("Standby Threshold", StandbyMenu)
    
    ; Free memory threshold submenu (build once)
    FreeMemMenu := Menu()
    for mb in Config.FreeMemoryThresholdOptions {
        label := mb == 0 ? "Disabled" : mb " MB"
        FreeMemMenu.Add(label, SetFreeMemoryThreshold.Bind(mb))
        if mb == Config.FreeMemoryThresholdMB
            FreeMemMenu.Check(label)
    }
    A_TrayMenu.Add("Free Memory Threshold", FreeMemMenu)
    
    A_TrayMenu.Add()
    A_TrayMenu.Add("Quit", QuitApp)
}

GetStatusText() {
    status := State.Paused ? "Paused" : "Running"
    standbyMB := GetStandbyListMB()
    freeMB := GetFreeMemoryMB()
    return "Status: " status " | EVE: " State.EveTrimmed "/" State.EveTotal " | Standby: " standbyMB "MB | Free: " freeMB "MB"
}

UpdateTrayTip() {
    global StatusMenuItem
    newStatus := GetStatusText()
    
    ; Only update menu if status changed
    if newStatus != StatusMenuItem {
        try {
            A_TrayMenu.Rename(StatusMenuItem, newStatus)
            StatusMenuItem := newStatus
        }
    }
    
    A_IconTip := "EVE RAM Trimmer`n" newStatus
}

UpdatePauseMenuItem() {
    pauseText := State.Paused ? "Resume" : "Pause"
    try {
        if State.Paused
            A_TrayMenu.Rename("Pause", "Resume")
        else
            A_TrayMenu.Rename("Resume", "Pause")
    }
}

TogglePause(*) {
    State.Paused := !State.Paused
    UpdatePauseMenuItem()
    UpdateTrayTip()
}

SetInterval(ms, *) {
    global Config
    Config.IntervalMs := ms
    SetTimer(TrimLoop, Config.IntervalMs)
}

SetStandbyThreshold(mb, *) {
    global Config
    Config.StandbyThresholdMB := mb
    ; Warn if enabling standby clearing without admin rights
    if mb > 0 && !A_IsAdmin
        WarnNotAdmin()
}

SetFreeMemoryThreshold(mb, *) {
    global Config
    Config.FreeMemoryThresholdMB := mb
}

QuitApp(*) {
    ExitApp()
}

; ============== Admin Warning ==============
WarnNotAdmin() {
    MsgBox("Standby list clearing requires administrator privileges.`n`nPlease restart the script as administrator.", "EVE RAM Trimmer - Not Admin", "Icon!")
}

; ============== Main ==============
LoadConfig()

; Warn if standby clearing is enabled without admin
if (Config.StandbyThresholdMB > 0) && !A_IsAdmin
    WarnNotAdmin()

; Setup tray
A_IconTip := "EVE RAM Trimmer"
BuildTrayMenu()

; Start trim loop
SetTimer(TrimLoop, Config.IntervalMs)
TrimLoop()  ; Run immediately once
