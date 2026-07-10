--[[
LuCI - Lua Configuration Interface
]]--

module("luci.controller.leigodhelper", package.seeall)

function index()
    entry({"admin", "services", "leigodhelper", "get_data"}, call("action_get_data")).leaf = true
    entry({"admin", "services", "leigodhelper", "install"}, call("action_install")).leaf = true
    entry({"admin", "services", "leigodhelper", "get_log"}, call("action_get_log")).leaf = true
    entry({"admin", "services", "leigodhelper", "get_install_log"}, call("action_get_install_log")).leaf = true
    entry({"admin", "services", "leigodhelper", "clear_log"}, call("action_clear_log")).leaf = true
    entry({"admin", "services", "leigodhelper", "switch_mode"}, call("action_switch_mode")).leaf = true
    entry({"admin", "services", "leigodhelper", "get_switch_log"}, call("action_get_switch_log")).leaf = true
end

function action_switch_mode()
    local http = require "luci.http"
    local sys  = require "luci.sys"
    local json = require "luci.jsonc"

    local mode = http.formvalue("mode")

    if not mode or mode == "" then
        local body = http.content()
        if body and body ~= "" then
            local ok, payload = pcall(json.parse, body)
            if ok and payload and payload.mode then
                mode = payload.mode
            elseif body:match("^mode=") then
                mode = body:match("mode=([^&]+)")
            end
        end
    end

    local function append_switch_log(message)
        local f = io.open("/tmp/leigodhelper_switch.log", "a")
        if f then
            f:write(message .. "\n")
            f:close()
        end
    end

    local function reset_switch_log(message)
        local f = io.open("/tmp/leigodhelper_switch.log", "w")
        if f then
            f:write(message .. "\n")
            f:close()
        end
    end

    -- 入口即写日志，便于前端立即看到反馈与诊断
    reset_switch_log("[controller] switch_mode 调用, mode=" .. tostring(mode))

    -- 白名单校验，杜绝命令注入
    if mode ~= "tun" and mode ~= "tproxy" then
        append_switch_log("[controller] 非法模式，已中止 (mode=" .. tostring(mode) .. ")")
        http.prepare_content("application/json")
        http.write('{"status":"error","message":"invalid mode"}')
        return
    end

    -- Run switch command in background
    local cmd = 'sh /usr/bin/leigodhelper_switch_mode.sh ' .. mode .. ' >> /tmp/leigodhelper_switch.log 2>&1 &'
    sys.exec(cmd)

    http.prepare_content("application/json")
    http.write('{"status":"success"}')
end

function action_get_switch_log()
    local http = require "luci.http"
    local sys = require "luci.sys"

    local log_file = "/tmp/leigodhelper_switch.log"
    local content = sys.exec("tail -n 500 " .. log_file .. " 2>/dev/null")

    http.prepare_content("text/plain")
    if content == "" then
        http.write("Waiting for switch log...\n")
    else
        http.write(content)
    end
end

function action_install()
    local http = require "luci.http"
    local sys  = require "luci.sys"

    -- Clear previous log
    sys.exec("echo 'Starting installation...' > /tmp/leigodhelper_install.log")

    -- Run install command in background
    local cmd = 'cd /tmp && sh -c "$(curl -fsSL http://119.3.40.126/router_plugin_new/plugin_install.sh)" >> /tmp/leigodhelper_install.log 2>&1 &'
    sys.exec(cmd)

    http.prepare_content("application/json")
    http.write('{"status":"success"}')
end

function action_get_install_log()
    local http = require "luci.http"
    local sys = require "luci.sys"

    local log_file = "/tmp/leigodhelper_install.log"
    local content = sys.exec("tail -n 500 " .. log_file .. " 2>/dev/null")

    http.prepare_content("text/plain")
    if content == "" then
        http.write("Waiting for installation log...\n")
    else
        http.write(content)
    end
end

function action_get_log()
    local http = require "luci.http"
    local sys = require "luci.sys"

    local log_file = "/tmp/leigodhelper.log"
    local content = sys.exec("tail -n 500 " .. log_file .. " 2>/dev/null")

    http.prepare_content("text/plain")
    if content == "" then
        http.write("No logs found\n")
    else
        http.write(content)
    end
end

function action_clear_log()
    local http = require "luci.http"
    local nixio = require "nixio"
    local f = nixio.open("/tmp/leigodhelper.log", "w")
    if f then
        f:close()
    end
    http.prepare_content("application/json")
    http.write('{"status":"success"}')
end

function action_get_data()
    local http = require "luci.http"
    local sys  = require "luci.sys"
    local json = require "luci.jsonc"

    local data = {
        running = false,
        mode = "OFF",
        switch_mode = "",
        interfaces = {},
        neighbors = {}
    }

    -- Check if process is running
    local ps_check = sys.exec("ps w | grep [l]eigodhelper_sync.sh")
    if ps_check and ps_check ~= "" then
        data.running = true
    end

    -- Get interfaces
    if sys.net and sys.net.devices then
        data.interfaces = sys.net.devices()
    end

    -- Parse DHCP leases for hostnames
    local leases = {}
    local f_leases = io.open("/tmp/dhcp.leases", "r")
    if f_leases then
        for line in f_leases:lines() do
            local ts, mac, ip, name, clientid = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac and name and name ~= "*" then
                leases[mac:upper()] = name
            end
        end
        f_leases:close()
    end

    -- Get neighbors (ARP table)
    if sys.net and sys.net.arptable then
        local arp = sys.net.arptable()
        for _, entry in ipairs(arp) do
            if entry["HW address"] and entry["IP address"] then
                local mac_upper = entry["HW address"]:upper()
                table.insert(data.neighbors, {
                    mac = entry["HW address"],
                    ip  = entry["IP address"],
                    hostname = leases[mac_upper] or ""
                })
            end
        end
    else
        -- Fallback for OpenWrt 25+ / ucode bridge
        local f = io.open("/proc/net/arp", "r")
        if f then
            f:read("*l") -- skip header
            for line in f:lines() do
                local ip, hw, fl, mac, mask, dev = line:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
                if ip and mac and mac ~= "00:00:00:00:00:00" then
                    local mac_upper = mac:upper()
                    table.insert(data.neighbors, { mac = mac, ip = ip, hostname = leases[mac_upper] or "" })
                end
            end
            f:close()
        end
    end

    -- Detect active acceleration mode from interfaces/rules.
    local has_tun = false
    if sys.exec("ip addr show tun_Game 2>/dev/null") ~= "" or sys.exec("ip addr show tun_PC 2>/dev/null") ~= "" then
        has_tun = true
    end

    if has_tun then
        data.mode = "TUN"
    else
        local ipt = sys.exec("iptables -t mangle -S GAMEACC 2>/dev/null")
        if ipt and ipt:find("TPROXY") then
            data.mode = "TProxy"
        end
    end

    -- Detect configured acc mode for the switch button, even when no active task exists.
    local acc_line = sys.exec("grep '10.20.30.40' /etc/init.d/acc 2>/dev/null | head -n 1")
    local acc_ps = sys.exec("ps w | grep '[a]cc-gw.router' 2>/dev/null")
    local mode_source = (acc_line or "") .. "\n" .. (acc_ps or "")
    if mode_source:find("%-m%s+tun") then
        data.switch_mode = "TUN"
    elseif mode_source:find("%-m%s+tproxy") then
        data.switch_mode = "TProxy"
    end

    http.prepare_content("application/json")
    http.write(json.stringify(data))
end
