--[[--
MatePad Paper（HMW-W09）墨水屏全刷插件。

== 为什么 KOReader 在华为上刷不出来 ==
KOReader 的刷屏链路（master 实证）：

    ReaderView:recalculate()
      -> UIManager:setDirty(..., "partial")
      -> UIManager:_refresh()          -- refresh_count 累加，到 FULL_REFRESH_COUNT 时升级为 "full"
      -> UIManager:_repaint()
      -> refresh_methods.full = Screen.refreshFull
      -> fb:refreshFull()              -- base/ffi/framebuffer.lua
      -> framebuffer:refreshFullImp()  -- base/ffi/framebuffer_android.lua
      -> self:_updateWindow()          -- 只把像素 blit 进 ANativeWindow 再 unlockAndPost
      -> if has_eink_screen then self:_updateFull() -> android.einkUpdate(mode) end

`local has_eink_screen = android.isEink()`，而 android.isEink() 背后是
android-luajit-launcher 的 EPDFactory：它靠 Build 字段硬编码了 20+ 家厂商白名单，
**没有 HUAWEI / HMW**，未命中就落到 FakeEPDController（setEpdMode 空实现）=> isEink() = false。

后果（三连）：
  1. Device:hasEinkScreen() == false
  2. 整个 E-ink 设置子菜单被跳过 -> 用户看不到"全刷间隔"选项
  3. refreshFullImp 里 _updateFull() 不执行 -> 只做普通重绘，无波形，残影不清

注意：has_eink_screen 是模块加载期一次性求值的，运行期改 android.isEink 无效。

== 本插件做什么 ==
按"页"计数（PageUpdate），每 N 页触发一次真正的全屏刷新动作。动作可选：
  white      全屏白闪（纯软件，无依赖，默认）
  blackwhite 黑->白 两段闪（像素翻转量最大，最容易激出全量波形）
  cmd        执行探测到的系统命令（am broadcast / am start / service call ...）
  epd        直接调 android.einkUpdate()（仅当厂商驱动存在时才有意义）

外加两个实用功能：
  * 立即全刷一次：先肉眼确认哪一档真的清残影
  * 探测本机全刷接口：在平板本地跑只读命令，把证据写成报告文件（不需要电脑/adb）

@module huaweieink
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local NAME = "huaweieink"
local LOG_PREFIX = "[HuaweiEink] "

local K = {
    enabled   = NAME .. "_enabled",
    rate      = NAME .. "_rate",
    mode      = NAME .. "_mode",
    hold      = NAME .. "_hold_ms",
    command   = NAME .. "_command",
    hook_full = NAME .. "_hook_full",
    epd_mode  = NAME .. "_epd_mode",
    native_menu = NAME .. "_native_menu",
    native_method = NAME .. "_native_method",
}

local DEFAULTS = {
    enabled   = true,
    rate      = 0,          -- 0 = 插件自己的翻页计数关闭；改由 KOReader 原生菜单控制
    mode      = "native",   -- 本机实测可用的真正全刷
    hold      = 120,
    command   = "",
    hook_full = true,       -- 接管 KOReader 原生全刷请求（原生菜单要靠它才有硬件效果）
    epd_mode  = 98,         -- UI_EINK_GC16_FULL_MODE
    native_menu = true,     -- 伪装 hasEinkScreen，让 KOReader 原生 E-ink 菜单出现
    native_method = "next", -- next=作用于下一次 post（正确）；immediate=立即刷当前画面
}

-- ---------------------------------------------------------------------------
-- 华为 e-ink framework 常量（实测自 /system/framework/eink.framework.jar）
--
-- 该 jar 里有一套 android.eink.* 的 EPC（E Ink T1000 TCON）控制 API，其中：
--     Landroid/eink/EPDCDevice;-><init>()V
--     Landroid/eink/EPDCDevice;->forceRefresh(I)V
--     Landroid/eink/EPDCDevice;->getEpdcLastMode()I
--     Landroid/eink/EPDCDevice;->getT1000Info()Ljava/lang/String;   (static)
-- 模式值来自 Landroid/eink/api/EinkMode; 的静态字段（本机 DEX 解析出的真实数值）：
--     98  = UI_EINK_GC16_FULL_MODE      (WAIT|FULL|GC16)   ← 标准全刷
--     97  = UI_EINK_DU_FULL_MODE        (WAIT|FULL|DU)
--     99  = UI_EINK_GL16_FULL_MODE_4BIT (WAIT|FULL|GL16)
--     32  = EINK_UPDATE_MODE_FULL       (仅 FULL 位)
-- ---------------------------------------------------------------------------
local EPDC_GC16_FULL = 98
local EPDC_DU_FULL = 97
local EPDC_GL16_FULL = 99
local EPDC_FULL_ONLY = 32

-- ---------------------------------------------------------------------------
-- 基础工具
-- ---------------------------------------------------------------------------

local function log(msg)
    logger.info(LOG_PREFIX .. tostring(msg))
end

local function default_of(key)
    return DEFAULTS[key:gsub("^" .. NAME .. "_", "")]
end

local function setting(key)
    if G_reader_settings then
        local ok, val = pcall(function() return G_reader_settings:readSetting(key) end)
        if ok and val ~= nil then return val end
    end
    return default_of(key)
end

local function save(key, value)
    if G_reader_settings then
        local ok = pcall(function() G_reader_settings:saveSetting(key, value) end)
        if not ok then log("保存设置失败: " .. key) end
    end
end

local function get_android()
    local ok, mod = pcall(require, "android")
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function device_model()
    local android = get_android()
    if android and android.prop and android.prop.model then
        return tostring(android.prop.model)
    end
    return ""
end

local function device_product()
    local android = get_android()
    if android and android.prop and android.prop.product then
        return tostring(android.prop.product)
    end
    return ""
end

local function is_huawei_eink()
    local m, p = device_model():upper(), device_product():upper()
    return m:find("HMW", 1, true) ~= nil or p:find("HMW", 1, true) ~= nil
end

local function screen_size()
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.screen then
        local ok2, size = pcall(function() return Device.screen:getSize() end)
        if ok2 and size and size.w and size.h then return size.w, size.h end
    end
    return nil, nil
end

-- 跑 shell，返回 exit_code, stdout。三层兜底（不同版本能力不同）：
--   1) android.stdout(argv...)  2) ffiUtil.popenRead(cmd)  3) io.popen(cmd)
local function run_shell(cmd)
    local android = get_android()
    if android and type(android.stdout) == "function" then
        local ok, out = pcall(android.stdout, "sh", "-c", cmd)
        if ok and out ~= nil then return 0, tostring(out) end
    end

    local ok, FFIUtil = pcall(require, "ffi/util")
    if ok and FFIUtil and FFIUtil.popenRead then
        local ok2, out = pcall(FFIUtil.popenRead, cmd)
        if ok2 and out ~= nil then return 0, tostring(out) end
    end

    local ok3, out = pcall(function()
        local fh = io.popen(cmd .. " 2>&1")
        if not fh then return nil end
        local s = fh:read("*a")
        fh:close()
        return s
    end)
    if ok3 then return 0, tostring(out or "") end
    return -1, tostring(out or "")
end

-- ---------------------------------------------------------------------------
-- 全屏纯色覆盖层
-- ---------------------------------------------------------------------------

local FlashOverlay = Widget:extend{
    -- Blitbuffer.COLOR_* 在 RGB32 下同样有效
    --（framebuffer_android.lua 自己就用 BB.COLOR_WHITE 去 fill 一个 BBRGB32 缓冲）
    color = Blitbuffer.COLOR_WHITE,
}

function FlashOverlay:paintTo(bb, _x, _y)
    bb:paintRect(0, 0, bb:getWidth(), bb:getHeight(), self.color)
end

-- ---------------------------------------------------------------------------
-- 插件主体
-- ---------------------------------------------------------------------------

local HuaweiEink = WidgetContainer:extend{
    name = NAME,
    is_doc_only = false,
}

function HuaweiEink:init()
    self.page_count = 0
    self.busy = false
    self._cooldown = false
    self._last_page = nil
    self._last_stamp = nil

    if not get_android() then
        log("非 Android 环境，插件保持静默")
        return
    end

    log(string.format("初始化 model=%s product=%s isHuaweiEink=%s",
        device_model(), device_product(), tostring(is_huawei_eink())))

    local android = get_android()
    if android and type(android.isEink) == "function" then
        local ok, supported, platform = pcall(android.isEink)
        log(string.format("android.isEink() -> supported=%s platform=%s",
            tostring(supported), tostring(platform)))
    end

    self:install_page_hook()
    if setting(K.native_menu) then
        self:install_native_menu()
    end
    if setting(K.hook_full) then
        self:install_full_refresh_hook()
    end

    -- 启动自检：写一个 boot 标记文件，便于从 adb 侧确认"插件到底有没有加载"
    self:write_boot_marker()

    -- 若存在触发文件，就跑一次自动化探测（方便不开 UI 也能取数据）
    self:maybe_run_auto_probe()
end

function HuaweiEink:write_boot_marker()
    local android = get_android()
    local dir = nil
    if android and type(android.getExternalStoragePath) == "function" then
        local ok, ext = pcall(android.getExternalStoragePath)
        if ok and ext then dir = ext .. "/koreader" end
    end
    dir = dir or "/sdcard/koreader"
    local fh = io.open(dir .. "/huaweieink_boot.txt", "w")
    if fh then
        fh:write(string.format("loaded %s\nmodel=%s\nproduct=%s\nisHuaweiEink=%s\nmode=%s\nrate=%s\n",
            os.date("%Y-%m-%d %H:%M:%S"), device_model(), device_product(),
            tostring(is_huawei_eink()), tostring(setting(K.mode)), tostring(setting(K.rate))))
        fh:close()
    end
end

-- 触发文件协议：/sdcard/koreader/huaweieink_run 存在时，
-- 依次执行 native 全刷 / EPDC 探测，并把结果写到 huaweieink_result.txt。
function HuaweiEink:maybe_run_auto_probe()
    local android = get_android()
    local dir = "/sdcard/koreader"
    if android and type(android.getExternalStoragePath) == "function" then
        local ok, ext = pcall(android.getExternalStoragePath)
        if ok and ext then dir = ext .. "/koreader" end
    end

    local trigger = dir .. "/huaweieink_run"
    local fh = io.open(trigger, "r")
    if not fh then return end
    fh:close()

    -- 推迟到界面完全起来之后再跑：forceRefresh 需要有可用的显示管线
    UIManager:scheduleIn(6, function() self:_do_auto_probe(dir) end)
end

function HuaweiEink:_do_auto_probe(dir)
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s) end

    add("=== huaweieink auto probe " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
    add("model=" .. device_model() .. " product=" .. device_product())

    add("--- EPDC 状态（调用前）---")
    for _i, line in ipairs(self:probe_epdc()) do add(line) end

    add("--- 原生 E-ink 菜单检查 ---")
    local okD, Device = pcall(require, "device")
    if okD and Device then
        local ok3, res = pcall(function() return Device:hasEinkScreen() end)
        add("Device:hasEinkScreen() = " .. tostring(ok3 and res))
    end
    local okT, tbl = pcall(dofile, "frontend/ui/elements/screen_eink_opt_menu_table.lua")
    if okT and type(tbl) == "table" and tbl.sub_item_table then
        -- 注意：菜单文案会被 gettext 本地化，必须用 _() 生成的同一份字符串比较
        local gt = require("gettext")
        local has_refresh = false
        for _i, item in ipairs(tbl.sub_item_table) do
            if item.text == gt("Full refresh rate") then has_refresh = true end
        end
        add("E-ink 菜单项数 = " .. tostring(#tbl.sub_item_table))
        add("菜单已含「全刷间隔」= " .. tostring(has_refresh))
    else
        add("读取 E-ink 菜单表失败: " .. tostring(tbl))
    end
    local okR, day, night = pcall(function() return UIManager:getRefreshRate() end)
    add(string.format("UIManager:getRefreshRate() day=%s night=%s",
        tostring(day), tostring(night)))

    add("--- 原生计数 + 硬件全刷联调（把间隔临时设为每 1 页）---")
    local okE, Event = pcall(require, "ui/event")
    if okE and Event then
        UIManager:broadcastEvent(Event:new("SetBothRefreshRates", 1))
        for k = 1, 3 do
            UIManager:setDirty(nil, "partial")
            local t0 = os.time()
            while os.time() - t0 < 1 do end
            add("  已触发第 " .. k .. " 次 partial 刷新")
        end
        UIManager:broadcastEvent(Event:new("SetBothRefreshRates", day or 6))
        add("  已恢复间隔为 " .. tostring(day or 6))
    else
        add("  无法构造 Event，跳过")
    end

    add("--- setForceNextPostMode 时序测试（关键）---")
    local before_next = nil
    pcall(function()
        with_epdc(function(env, cls) before_next = epdc_get_int(env, cls, "getEpdcLastMode") end)
    end)
    add("  lastMode before      = " .. tostring(before_next))
    local okn, errn = self:refresh_by_native_next(98)
    add("  setForceNextPostMode(98) -> ok=" .. tostring(okn) .. " err=" .. tostring(errn))
    UIManager:setDirty(nil, "partial")
    local tn = os.time()
    while os.time() - tn < 1 do end
    local after_next = nil
    pcall(function()
        with_epdc(function(env, cls) after_next = epdc_get_int(env, cls, "getEpdcLastMode") end)
    end)
    add("  lastMode after post  = " .. tostring(after_next))

    add("--- 模式扫描 ---")
    for _i, line in ipairs(self:run_native_sweep({ 98, 97, 99 })) do add(line) end

    add("--- EPDC 状态（调用后）---")
    for _i, line in ipairs(self:probe_epdc()) do add(line) end

    local outf = io.open(dir .. "/huaweieink_result.txt", "w")
    if outf then
        outf:write(table.concat(lines, "\n") .. "\n")
        outf:close()
    end
    os.remove(dir .. "/huaweieink_run")
end

-- 翻页计数：ReaderView:onPageUpdate 是最准的"这一页已呈现"钩子；
-- 同时兜底接 PageUpdate 事件（不同版本派发路径不同），用页码去重。
function HuaweiEink:install_page_hook()
    if self._page_hook_installed then return end

    local ok, ReaderView = pcall(require, "apps/reader/modules/readerview")
    if ok and type(ReaderView) == "table" and type(ReaderView.onPageUpdate) == "function" then
        local orig = ReaderView.onPageUpdate
        local plugin = self
        ReaderView.onPageUpdate = function(rv_self, page, ...)
            local r = orig(rv_self, page, ...)
            pcall(function() plugin:on_page_shown(page) end)
            return r
        end
        self._page_hook_installed = true
        log("已挂载 ReaderView:onPageUpdate 计数钩子")
    else
        log("ReaderView:onPageUpdate 不可用，依赖 PageUpdate 事件兜底")
    end
end

-- 可选：接管 KOReader 自己的"全刷请求"（语义与原生完全对齐，但菜单开合也会闪）。
function HuaweiEink:install_full_refresh_hook()
    if self._full_hook_installed then return end
    local ok, Device = pcall(require, "device")
    if not ok or not Device or not Device.screen then return end
    local fb = Device.screen

    -- 真正要执行的动作：优先用"作用于下一帧"的 setForceNextPostMode
    local plugin = self
    local function native_full_refresh()
        if plugin.busy or plugin._cooldown then return end
        local android = get_android()
        if android and type(android.jni) == "table" then
            if (setting(K.native_method) or "next") == "immediate" then
                pcall(function() plugin:refresh_by_native() end)
            else
                pcall(function() plugin:refresh_by_native_next() end)
            end
        else
            pcall(function() plugin:do_refresh("koreader_full") end)
        end
    end

    -- KOReader 各版本这两个入口的名字可能变，两个都试，谁在就包谁
    if type(fb.refreshFullImp) == "function" then
        local orig = fb.refreshFullImp
        fb.refreshFullImp = function(fb_self, ...)
            -- 先声明"这一帧要用全刷波形"，再让 orig 把帧 post 出去。
            -- 这样闪屏与新页面是同一次刷新，不会出现"先闪旧画面再翻页"。
            native_full_refresh()
            return orig(fb_self, ...)
        end
        self._full_hook_installed = true
        log("已接管 KOReader 的全刷请求 (refreshFullImp)，原生全刷间隔设置从此生效")
        return
    end

    if type(fb.refreshFull) == "function" then
        local orig = fb.refreshFull
        fb.refreshFull = function(fb_self, ...)
            native_full_refresh()
            return orig(fb_self, ...)
        end
        self._full_hook_installed = true
        log("已接管 KOReader 的全刷请求 (refreshFull)，原生全刷间隔设置从此生效")
        return
    end

    log("警告：这个 KOReader 版本既没有 refreshFullImp 也没有 refreshFull，全刷间隔会失效")
end

-- ---------------------------------------------------------------------------
-- 让 KOReader 原生 E-ink 菜单回来
--
-- KOReader 的「设置 → 屏幕 → E-ink settings → Full refresh rate（全刷间隔）」
-- 整块菜单被这一行挡掉（screen_eink_opt_menu_table.lua）：
--     if Device:hasEinkScreen() then table.insert(..., dofile(".../refresh_menu_table.lua")) end
-- 而 Android 设备上 hasEinkScreen() 恒等于 android.isEink() —— 华为不在 EPDFactory
-- 白名单里，所以是 false。
--
-- 我们把 Device:hasEinkScreen() 覆盖成 true，原生菜单就原样出现了，
-- 选项、文案、计数逻辑、设置键（refresh_rate_*）全部是 KOReader 自己的，
-- 和 Kindle/Kobo 上一模一样。真正的硬件全刷由 refreshFullImp 钩子补上。
-- ---------------------------------------------------------------------------
function HuaweiEink:install_native_menu()
    if self._native_menu_installed then return end
    local ok, Device = pcall(require, "device")
    if not ok or not Device then return end

    local already = false
    if type(Device.hasEinkScreen) == "function" then
        local ok2, res = pcall(function() return Device.hasEinkScreen(Device) end)
        already = ok2 and res and true or false
    end
    if already then
        log("设备本就报告 e-ink，无需伪装")
        self._native_menu_installed = true
        return
    end

    -- 记住原始实现，便于菜单里关掉
    self._orig_has_eink = Device.hasEinkScreen
    Device.hasEinkScreen = function() return true end
    self._native_menu_installed = true
    log("已启用原生 E-ink 菜单（Device:hasEinkScreen -> true）")
end

function HuaweiEink:disable_native_menu()
    local ok, Device = pcall(require, "device")
    if not ok or not Device then return end
    if self._orig_has_eink then
        Device.hasEinkScreen = self._orig_has_eink
    else
        Device.hasEinkScreen = function() return false end
    end
    log("已关闭原生 E-ink 菜单伪装")
end

function HuaweiEink:onPageUpdate(page)
    self:on_page_shown(page)
end

function HuaweiEink:on_page_shown(page)
    if not setting(K.enabled) then return end

    -- 去重：同一个翻页事件可能既走 ReaderView 钩子、又走事件派发。
    -- 用页码判定最可靠（os.clock 是 CPU 时间，阅读时几乎不走，做时间窗会误判）。
    if page ~= nil then
        if self._last_page == page then return end
        self._last_page = page
    else
        local now = os.time()
        if self._last_stamp == now then return end
        self._last_stamp = now
    end

    self.page_count = (self.page_count or 0) + 1
    local rate = tonumber(setting(K.rate)) or DEFAULTS.rate
    log(string.format("翻页 #%d / %d (page=%s)", self.page_count, rate, tostring(page)))

    if rate > 0 and self.page_count >= rate then
        self.page_count = 0
        self:do_refresh("auto")
    end
end

-- ---------------------------------------------------------------------------
-- 触发
-- ---------------------------------------------------------------------------

function HuaweiEink:do_refresh(reason)
    if self.busy or self._cooldown then
        log("上一次全刷未结束，跳过")
        return false
    end
    self.busy = true

    local mode = setting(K.mode)
    log(string.format("触发全刷 reason=%s mode=%s", tostring(reason), tostring(mode)))

    local ok, err
    if mode == "cmd" then
        ok, err = self:refresh_by_command()
    elseif mode == "native" then
        ok, err = self:refresh_by_native()
    elseif mode == "epd" then
        ok, err = self:refresh_by_epd()
    elseif mode == "blackwhite" then
        ok, err = self:refresh_by_flash(2)
    elseif mode == "multi" then
        ok, err = self:refresh_by_flash(4)
    else
        ok, err = self:refresh_by_flash(1)
    end

    if not ok then log("全刷失败: " .. tostring(err)) end
    if not ok then self:_end_cycle() end -- 闪屏成功时由回调解锁
    return ok
end

-- 结束一次刷新周期：解锁 + 300ms 冷却，防止钩子自激
function HuaweiEink:_end_cycle()
    self.busy = false
    self._cooldown = true
    UIManager:scheduleIn(0.3, function() self._cooldown = false end)
end

function HuaweiEink:refresh_by_command()
    local cmd = setting(K.command)
    if not cmd or cmd == "" then
        return false, "cmd 模式但未配置命令"
    end
    local rc, out = run_shell(cmd)
    local flat = tostring(out or ""):gsub("%s+", " "):sub(1, 300)
    log(string.format("命令 rc=%s out=%s", tostring(rc), flat))
    return true
end

function HuaweiEink:refresh_by_epd()
    local android = get_android()
    if not android then return false, "非 Android" end
    if type(android.einkUpdate) ~= "function" or type(android.getEinkConstants) ~= "function" then
        return false, "当前构建没有 einkUpdate/getEinkConstants"
    end
    local ok, full = pcall(android.getEinkConstants)
    if not ok or not full then
        return false, "getEinkConstants() 返回空（说明没有厂商 EPD 驱动）"
    end
    local ok2, err = pcall(android.einkUpdate, full)
    if ok2 then log("已调用 android.einkUpdate(" .. tostring(full) .. ")") end
    return ok2, err
end

-- ---------------------------------------------------------------------------
-- 原生全刷：JNI 反射调用华为 e-ink framework
--
-- 实测（DEX 解析 /system/framework/eink.framework.jar，本机 Android 10）：
--     static void   android.eink.EPDCDevice.forceRefresh(int)
--     static int    android.eink.EPDCDevice.getEpdcLastMode()
--     static int    android.eink.EPDCDevice.getEpdcDefaultMode()
--     static void   android.eink.EPDCDevice.setForceNextPostMode(int)
--     static void   android.eink.EPDCDevice.setEpdcDefaultMode(int)
--     static String android.eink.EPDCDevice.getT1000Info()
--
-- 两个踩过的坑：
--  1) 这些方法全是 static，用 GetMethodID 会抛 NoSuchMethodError；
--  2) JNI 调用抛异常后若不 ExceptionClear 就继续调下一个，ART 会
--     直接 abort 整个进程（"unexpected pending exception"）。
--     所以下面每次 JNI 调用之后都立刻检查并清除异常。
-- ---------------------------------------------------------------------------

local function jni_call(env, fn, tag)
    local ok, res = pcall(fn)
    local pending = false
    local okchk, chk = pcall(function() return env[0].ExceptionCheck(env) end)
    if okchk and chk == 1 then
        pending = true
        pcall(function() env[0].ExceptionDescribe(env) end)
        pcall(function() env[0].ExceptionClear(env) end)
    end
    if not ok then return nil, tostring(res) end
    if pending then return nil, "Java 异常: " .. tostring(tag) end
    return res
end

-- 统一的 "拿到 EPDCDevice 类并执行 body" 包装
local function with_epdc(body)
    local android = get_android()
    if not android or type(android.jni) ~= "table" then
        return false, "这版 launcher 没有 android.jni，无法反射"
    end
    if not (android.app and android.app.activity and android.app.activity.vm) then
        return false, "拿不到 JavaVM"
    end

    local ok, err = pcall(function()
        android.jni:context(android.app.activity.vm, function(j)
            local env = j.env
            local cls, e1 = jni_call(env, function()
                return env[0].FindClass(env, "android/eink/EPDCDevice")
            end, "FindClass")
            if not cls then error(e1 or "FindClass 返回 NULL") end
            body(env, cls, j)
        end)
    end)
    return ok, err
end

local function epdc_get_int(env, cls, name)
    local mid, e1 = jni_call(env, function()
        return env[0].GetStaticMethodID(env, cls, name, "()I")
    end, "GetStaticMethodID " .. name)
    if not mid then return nil, e1 end
    local val, e2 = jni_call(env, function()
        return env[0].CallStaticIntMethod(env, cls, mid)
    end, "Call " .. name)
    if val == nil then return nil, e2 end
    return val
end

-- 设置"下一次 post 使用的模式"。
-- 这才是正确的调用方式：页面渲染完、帧 post 出去的那一刻才走全刷波形，
-- 而不是先把旧画面刷一遍（那会变成"先闪一下旧内容，再翻页"）。
function HuaweiEink:refresh_by_native_next(mode_override)
    local mode = tonumber(mode_override) or tonumber(setting(K.epd_mode)) or EPDC_GC16_FULL
    local ffi = require("ffi")

    local ok, err = with_epdc(function(env, cls)
        local mid, e1 = jni_call(env, function()
            return env[0].GetStaticMethodID(env, cls, "setForceNextPostMode", "(I)V")
        end, "GetStaticMethodID setForceNextPostMode")
        if not mid then error(e1 or "没有 static setForceNextPostMode(I)V") end

        local _r, e2 = jni_call(env, function()
            env[0].CallStaticVoidMethod(env, cls, mid, ffi.cast("int32_t", mode))
        end, "CallStaticVoidMethod setForceNextPostMode")
        if e2 then error(e2) end
    end)

    if not ok then log("设置下一帧全刷失败: " .. tostring(err)) end
    return ok, err
end

-- mode 可选；不传就用设置里的值
function HuaweiEink:refresh_by_native(mode_override)
    local mode = tonumber(mode_override) or tonumber(setting(K.epd_mode)) or EPDC_GC16_FULL
    local ffi = require("ffi")

    local ok, err = with_epdc(function(env, cls)
        local mid, e1 = jni_call(env, function()
            return env[0].GetStaticMethodID(env, cls, "forceRefresh", "(I)V")
        end, "GetStaticMethodID forceRefresh")
        if not mid then error(e1 or "没有 static forceRefresh(I)V") end

        local _r, e2 = jni_call(env, function()
            env[0].CallStaticVoidMethod(env, cls, mid, ffi.cast("int32_t", mode))
        end, "CallStaticVoidMethod forceRefresh")
        if e2 then error(e2) end
    end)

    if ok then
        log(string.format("原生全刷成功 EPDCDevice.forceRefresh(%d)", mode))
    else
        log("原生全刷失败: " .. tostring(err))
    end
    return ok, err
end

-- 读取 EPDC 状态（写日志 / 菜单展示）
function HuaweiEink:probe_epdc()
    local out = {}
    local function add(s) out[#out + 1] = s end

    local ok, err = with_epdc(function(env, cls, j)
        local last = epdc_get_int(env, cls, "getEpdcLastMode")
        local def = epdc_get_int(env, cls, "getEpdcDefaultMode")
        add(string.format("getEpdcLastMode()    = %s", tostring(last)))
        add(string.format("getEpdcDefaultMode() = %s", tostring(def)))

        local mid, e1 = jni_call(env, function()
            return env[0].GetStaticMethodID(env, cls, "getT1000Info", "()Ljava/lang/String;")
        end, "GetStaticMethodID getT1000Info")
        if mid then
            local s = jni_call(env, function()
                return env[0].CallStaticObjectMethod(env, cls, mid)
            end, "Call getT1000Info")
            if s then
                local str = jni_call(env, function() return j:to_string(s) end, "to_string")
                add("getT1000Info() = " .. tostring(str))
            end
        end
    end)

    if not ok then add("EPDC 探测失败: " .. tostring(err)) end
    add("原生 E-ink 菜单已启用 = " .. tostring(self._native_menu_installed))
    add("全刷钩子已安装       = " .. tostring(self._full_hook_installed))
    return out
end

-- 扫描多个模式，把每次调用前后的 lastMode 记下来。
-- 配合 logcat 里 SurfaceFlinger 的 "current epdcMode is X" 就能确认是否真的生效。
function HuaweiEink:run_native_sweep(modes)
    local lines = {}
    local function add(s) lines[#lines + 1] = tostring(s) end

    for _i, mode in ipairs(modes) do
        local before = nil
        local ok0, err0 = with_epdc(function(env, cls)
            before = epdc_get_int(env, cls, "getEpdcLastMode")
        end)
        add(string.format("--- mode %d ---", mode))
        if not ok0 then add("  读取 lastMode 失败: " .. tostring(err0)) end
        add(string.format("  lastMode before = %s", tostring(before)))

        local ok, err = self:refresh_by_native(mode)
        add(string.format("  forceRefresh(%d) -> ok=%s err=%s", mode, tostring(ok), tostring(err)))

        local after = nil
        pcall(function()
            with_epdc(function(env, cls)
                after = epdc_get_int(env, cls, "getEpdcLastMode")
            end)
        end)
        add(string.format("  lastMode after  = %s", tostring(after)))

        -- 给显示控制器时间完成一次刷新
        local t = os.time()
        while os.time() - t < 2 do end
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- 软件闪屏（无依赖的兜底方案）
-- ---------------------------------------------------------------------------

-- 直接把一帧纯色推进屏幕缓冲并**同步 present**。
-- 为什么不用 UIManager 的覆盖层：UIManager 是"标记脏区 -> 下一帧统一重绘"，
-- 若当前版本没有 forceRePaint，白帧可能还没被 present 就被 close 掉 —— 屏幕上什么都不会发生。
-- 这里改成：Screen.bb:fill() + Screen:refreshFull()，走的就是 KOReader 自己的全刷路径
-- （framebuffer_android.lua: refreshFullImp -> _updateWindow -> ANativeWindow_unlockAndPost）。
-- 返回 "direct" 表示成功；nil 表示走不了，需要退化到 widget 覆盖层。
function HuaweiEink:_paint_frame_direct(color)
    local ok, Device = pcall(require, "device")
    if not ok or not Device or not Device.screen then return nil end
    local s = Device.screen
    if type(s.bb) ~= "table" or type(s.bb.fill) ~= "function"
        or type(s.refreshFull) ~= "function" then
        return nil
    end
    local ok2 = pcall(function()
        s.bb:fill(color)
        s:refreshFull()
    end)
    if ok2 then return "direct" end
    return nil
end

function HuaweiEink:_paint_and_hold(color, hold_ms, on_done)
    local via = self:_paint_frame_direct(color)
    local overlay

    if not via then
        -- 退化路径：铺一个整屏纯色 widget，尽量强制刷新
        local w, h = screen_size()
        overlay = FlashOverlay:new{ color = color }
        if w and h then
            overlay.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
        end
        UIManager:show(overlay)
        if type(UIManager.forceRePaint) == "function" then
            UIManager:forceRePaint()
        else
            UIManager:setDirty(overlay, "full")
        end
    end

    UIManager:scheduleIn(hold_ms / 1000, function()
        if overlay then UIManager:close(overlay) end
        -- 强制整屏重绘，把正文完整画回来（等价于 DeviceListener:onFullRefresh）
        UIManager:setDirty(nil, "full")
        if on_done then on_done() end
    end)
end

-- 颜色序列：1 段=纯白闪；2 段=黑->白；4 段=黑<->白 反复两轮。
-- 多段的意义：GC16 这类全刷波形本质上是让每个像素经历多次翻转，
-- 翻转次数越多，越有可能把驱动从"局部更新"推到"全量更新"。
function HuaweiEink:refresh_by_flash(cycles)
    local hold = tonumber(setting(K.hold)) or DEFAULTS.hold
    local seq
    if cycles == 1 then
        seq = { Blitbuffer.COLOR_WHITE }
    elseif cycles == 2 then
        seq = { Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE }
    else
        seq = { Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE,
                Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE }
    end
    self:_flash_sequence(seq, 1, hold)
    return true
end

function HuaweiEink:_flash_sequence(seq, idx, hold)
    if idx > #seq then
        self:_end_cycle()
        log("闪屏序列结束")
        return
    end
    local self_ = self
    self:_paint_and_hold(seq[idx], hold, function()
        self_:_flash_sequence(seq, idx + 1, hold)
    end)
end

-- ---------------------------------------------------------------------------
-- 本机取证：不依赖电脑 / adb
-- ---------------------------------------------------------------------------

local PROBE_COMMANDS = {
    { "机型/系统", "getprop ro.product.model; getprop ro.product.device; getprop ro.board.platform; "
        .. "getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.build.display.id" },
    { "hw 私有属性", "getprop | grep -iE 'hw|persist\\.sys' | head -60" },
    { "eink 属性", "getprop | grep -iE 'eink|epd|epaper|ink|paper|refresh|ghost'" },
    { "eink binder 服务", "service list | grep -iE 'eink|epd|epaper|ink|paper|refresh'" },
    { "binder 服务(前80)", "service list | head -80" },
    { "eink 相关包", "pm list packages -f | grep -iE 'eink|epd|paper|reader|ebook|book|note'" },
    { "设置/系统UI包路径", "pm list packages -f | grep -iE 'settings|systemui|controlcenter'" },
    { "系统设置 manifest 线索", "pm dump com.android.settings 2>/dev/null | grep -iE 'eink|refresh|paper' | head -40" },
    { "SystemUI manifest 线索", "for p in com.android.systemui com.huawei.systemui com.huawei.android.systemui; do "
        .. "echo \"[$p]\"; pm dump $p 2>/dev/null | grep -iE 'eink|refresh|tile' | head -25; done" },
    { "快捷开关 tile 枚举", "dumpsys statusbar 2>/dev/null | grep -iE 'tile|eink|refresh' | head -40" },
    { "cmd statusbar 支持吗", "cmd statusbar 2>&1 | head -20" },
    { "settings 键", "for ns in system secure global; do echo \"[$ns]\"; "
        .. "settings list $ns | grep -iE 'eink|epd|ink|refresh|paper|ghost'; done" },
    { "graphics 节点", "ls -l /sys/class/graphics/; ls -l /dev/ | grep -iE 'fb|eink|epd'" },
    { "eink sysfs", "find /sys/class /sys/devices -maxdepth 6 \\( -iname '*eink*' -o -iname '*epd*' \\) "
        .. "2>/dev/null | head -40" },
    { "厂商库", "ls /vendor/lib64 /vendor/lib64/hw /system/lib64 2>/dev/null | grep -iE 'eink|epd|ink'" },
    { "dumpsys 能跑吗", "dumpsys -l 2>&1 | grep -iE 'eink|epd|display|surface'" },
    { "shell 可用命令", "for c in am input settings service cmd pm dumpsys logcat; do "
        .. "printf '%s: ' $c; command -v $c || echo missing; done; id" },
}

function HuaweiEink:run_probe()
    if not get_android() then return nil, "非 Android 环境" end

    local lines = {}
    local function out(s) lines[#lines + 1] = s end

    out("MatePad Paper 全刷接口探测报告")
    out("时间: " .. os.date("%Y-%m-%d %H:%M:%S"))
    out(string.rep("=", 64))

    for _, item in ipairs(PROBE_COMMANDS) do
        local title, cmd = item[1], item[2]
        out("")
        out("#### " .. title)
        out("$ " .. cmd)
        local rc, stdout = run_shell(cmd)
        out((stdout ~= "" and stdout) or "(空)")
        if rc ~= 0 then out("(rc=" .. tostring(rc) .. ")") end
    end

    local text = table.concat(lines, "\n")
    local path
    local android = get_android()
    if android and type(android.getExternalStoragePath) == "function" then
        local ok, ext = pcall(android.getExternalStoragePath)
        if ok and ext then path = ext .. "/" .. NAME .. "_probe.txt" end
    end
    path = path or "/sdcard/" .. NAME .. "_probe.txt"

    local fh = io.open(path, "w")
    if fh then
        fh:write(text)
        fh:close()
        log("探测报告写入 " .. path)
    else
        log("写报告失败: " .. path)
        path = nil
    end

    return path, text
end

-- ---------------------------------------------------------------------------
-- 菜单
-- ---------------------------------------------------------------------------

function HuaweiEink:addToMainMenu(menu_items)
    local self_ = self

    menu_items.huaweieink_settings = {
        text = _("华为墨水屏全刷 (MatePad Paper)"),
        sorting_hint = "device",
        sub_item_table = {
            {
                text = _("启用"),
                checked_func = function() return setting(K.enabled) end,
                callback = function() save(K.enabled, not setting(K.enabled)) end,
            },
            {
                text = _("原生 E-ink 菜单（全刷间隔在那里设）"),
                checked_func = function()
                    local ok, Device = pcall(require, "device")
                    if not ok or not Device then return false end
                    local ok2, res = pcall(function() return Device:hasEinkScreen() end)
                    return (ok2 and res) and true or false
                end,
                callback = function()
                    local ok, Device = pcall(require, "device")
                    if not ok or not Device then return end
                    local ok2, res = pcall(function() return Device:hasEinkScreen() end)
                    if ok2 and res then
                        self_:disable_native_menu()
                        save(K.native_menu, false)
                    else
                        self_:install_native_menu()
                        save(K.native_menu, true)
                    end
                    log("原生 E-ink 菜单切换后需重启 KOReader 才会重建菜单")
                end,
            },
            {
                text_func = function()
                    local r = tonumber(setting(K.rate)) or 0
                    if r == 0 then
                        return _("插件自带翻页计数：已关闭（用上面的官方设置）")
                    end
                    return T(_("插件自带翻页计数：每 %1 页"), r)
                end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("每多少页全刷一次"),
                        info_text = _("0 = 关闭。建议 6~20。"),
                        value = tonumber(setting(K.rate)) or DEFAULTS.rate,
                        value_min = 0, value_max = 200,
                        value_step = 1, value_hold_step = 10,
                        ok_text = _("设置"),
                        callback = function(spin)
                            save(K.rate, spin.value)
                            log("间隔设为 " .. tostring(spin.value))
                        end,
                    })
                end,
            },
            {
                text = _("触发方式"),
                sub_item_table = {
                    {
                        text = _("原生全刷：EPDCDevice.forceRefresh（推荐）"),
                        checked_func = function() return setting(K.mode) == "native" end,
                        radio = true,
                        callback = function() save(K.mode, "native") end,
                    },
                    {
                        text = _("全屏白闪（纯软件，无依赖）"),
                        checked_func = function() return setting(K.mode) == "white" end,
                        radio = true,
                        callback = function() save(K.mode, "white") end,
                    },
                    {
                        text = _("黑->白 两段闪（更像全刷波形）"),
                        checked_func = function() return setting(K.mode) == "blackwhite" end,
                        radio = true,
                        callback = function() save(K.mode, "blackwhite") end,
                    },
                    {
                        text = _("黑<->白 多段闪（两轮，最接近 GC16）"),
                        checked_func = function() return setting(K.mode) == "multi" end,
                        radio = true,
                        callback = function() save(K.mode, "multi") end,
                    },
                    {
                        text = _("执行 shell 命令（探测到接口后用）"),
                        checked_func = function() return setting(K.mode) == "cmd" end,
                        radio = true,
                        callback = function() save(K.mode, "cmd") end,
                    },
                    {
                        text = _("调用 android.einkUpdate()（需厂商驱动）"),
                        checked_func = function() return setting(K.mode) == "epd" end,
                        radio = true,
                        callback = function() save(K.mode, "epd") end,
                    },
                },
            },
            {
                text_func = function()
                    return T(_("全刷波形模式值 %1"), tostring(setting(K.epd_mode)))
                end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("EPDC 模式值"),
                        info_text = _("98=GC16全刷 97=DU全刷 99=GL16全刷 32=仅FULL位"),
                        value = tonumber(setting(K.epd_mode)) or EPDC_GC16_FULL,
                        value_min = 0, value_max = 255,
                        value_step = 1, value_hold_step = 10,
                        ok_text = _("设置"),
                        callback = function(spin) save(K.epd_mode, spin.value) end,
                    })
                end,
            },
            {
                text = _("号外：查看 EPDC 状态（写日志）"),
                callback = function()
                    local out = self_:probe_epdc()
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{
                        text = table.concat(out, "\n") ~= "" and table.concat(out, "\n")
                            or _("没有取到任何信息"),
                        timeout = 10,
                    })
                    for _i, line in ipairs(out) do log("EPDC: " .. line) end
                end,
            },
            {
                text = _("原生调用时机"),
                sub_item_table = {
                    {
                        text = _("作用于下一帧（推荐，闪屏与新页面同步）"),
                        checked_func = function()
                            return (setting(K.native_method) or "next") ~= "immediate"
                        end,
                        radio = true,
                        callback = function() save(K.native_method, "next") end,
                    },
                    {
                        text = _("立即刷新当前画面（先闪旧内容再翻页）"),
                        checked_func = function()
                            return (setting(K.native_method) or "next") == "immediate"
                        end,
                        radio = true,
                        callback = function() save(K.native_method, "immediate") end,
                    },
                },
            },
            {
                text = _("自定义全刷命令"),
                keep_menu_open = true,
                callback = function()
                    local InputDialog = require("ui/widget/inputdialog")
                    local dialog
                    dialog = InputDialog:new{
                        title = _("全刷命令"),
                        description = _("例：am broadcast -a com.huawei.xxx.REFRESH"),
                        input = setting(K.command) or "",
                        input_hint = "am broadcast -a ...",
                        buttons = {{
                            { text = _("取消"), callback = function() UIManager:close(dialog) end },
                            { text = _("保存"), callback = function()
                                save(K.command, dialog:getInputText())
                                UIManager:close(dialog)
                            end },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text_func = function() return T(_("闪烁时长 %1 ms"), tostring(setting(K.hold))) end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("闪烁保持时长(毫秒)"),
                        value = tonumber(setting(K.hold)) or DEFAULTS.hold,
                        value_min = 40, value_max = 600,
                        value_step = 10, value_hold_step = 20,
                        ok_text = _("设置"),
                        callback = function(spin) save(K.hold, spin.value) end,
                    })
                end,
            },
            {
                text = _("接管 KOReader 的全刷请求（实验）"),
                checked_func = function() return setting(K.hook_full) end,
                callback = function()
                    save(K.hook_full, not setting(K.hook_full))
                    if setting(K.hook_full) then
                        self_:install_full_refresh_hook()
                    else
                        log("已关闭接管，需重启 KOReader 才完全恢复")
                    end
                end,
            },
            {
                text = _("立即全刷一次（测试）"),
                callback = function() self_:do_refresh("manual") end,
            },
            {
                text = _("重置翻页计数"),
                callback = function() self_.page_count = 0 end,
            },
            {
                text = _("探测本机全刷接口（生成报告）"),
                keep_menu_open = true,
                callback = function()
                    local path, text = self_:run_probe()
                    local InfoMessage = require("ui/widget/infomessage")
                    if path then
                        UIManager:show(InfoMessage:new{
                            text = T(_("探测完成，报告已保存：\n%1\n\n把这个文件发回即可定位接口。"), path),
                            timeout = 8,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = T(_("探测完成但写文件失败，前 600 字：\n%1"), (text or ""):sub(1, 600)),
                            timeout = 12,
                        })
                    end
                end,
            },
            {
                text = _("显示当前状态"),
                keep_menu_open = true,
                callback = function()
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{
                        text = T(_("机型: %1\n已翻页: %2\n间隔: 每 %3 页\n触发方式: %4"),
                            device_model(),
                            tostring(self_.page_count or 0),
                            tostring(setting(K.rate)),
                            tostring(setting(K.mode))),
                        timeout = 6,
                    })
                end,
            },
        },
    }
end

return HuaweiEink
