--[[
LuCI - Lua Configuration Interface
]]--

module("luci.controller.leigodhelper", package.seeall)

function index()
    entry({"admin", "services", "leigodhelper", "get_data"}, call("action_get_data")).leaf = true
    entry({"admin", "services", "leigodhelper", "install"}, call("action_install")).leaf = true
    entry({"admin", "services", "leigodhelper", "get_log"}, call("action_get_log")).leaf = true
    entry({"admin", "services", "leigodhelper", "clear_log"}, call("action_clear_log")).leaf = true
end

function action_install()
    local http = require "luci.http"
    local sys  = require "luci.sys"

    -- Clear previous log
    sys.exec("echo 'Starting installation...' > /tmp/leigodhelper_install.log")

    -- Run install command in background
    local cmd = 'cd /tmp && (curl -fsSL http://119.3.40.126/router_plugin_new/plugin_install.sh -o plugin_install.sh && sh plugin_install.sh) >> /tmp/leigodhelper_install.log 2>&1 &'
    sys.exec(cmd)

    http.prepare_content("application/json")
    http.write('{"status":"success"}')
end

function action_get_log()
    local http = require "luci.http"
    local sys = require "luci.sys"

    local log_file = "/tmp/leigodhelper.log"
    local content = sys.exec("tail -c 10240 " .. log_file .. " 2>/dev/null")

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

    -- Get neighbors (ARP table)
    if sys.net and sys.net.arptable then
        local arp = sys.net.arptable()
        for _, entry in ipairs(arp) do
            if entry["HW address"] and entry["IP address"] then
                table.insert(data.neighbors, {
                    mac = entry["HW address"],
                    ip  = entry["IP address"]
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
                    table.insert(data.neighbors, { mac = mac, ip = ip })
                end
            end
            f:close()
        end
    end

    -- Detect Mode
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

    http.prepare_content("application/json")
    http.write(json.stringify(data))
end
