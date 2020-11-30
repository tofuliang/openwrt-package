local n = require "luci.sys"
local i = require "nixio.fs"
local a, t, e
a = Map("webrestriction", translate("访问限制"), translate("使用黑名单或者白名单模式控制列表中的客户端是否能够连接到互联网。"))
a.template = "webrestriction/index"
t = a:section(TypedSection, "basic", translate("Running Status"))
t.anonymous = true
e = t:option(DummyValue, "webrestriction_status", translate("当前状态"))
e.template = "webrestriction/webrestriction"
e.value = translate("Collecting data...")
t = a:section(TypedSection, "basic", translate("全局设置"))
t.anonymous = true
t:tab("basic", translate("基本设置"))
e = t:taboption("basic", Flag, "enable", translate("开启"))
e.rmempty = false
e = t:taboption("basic", ListValue, "limit_type", translate("限制模式"))
e.default = "blacklist"
e:value("whitelist", translate("Whitelist"))
e:value("blacklist", translate("Blacklist"))
e.rmempty = false
t:tab("global_bypass", translate("IP白名单"))
local o = "/etc/config/webrestriction_bypass.list"
e = t:taboption("global_bypass", TextValue, "global_bypass_conf")
e.rows = 13
e.wrap = "off"
e.rmempty = true
e.cfgvalue = function(t, t)
    return i.readfile(o) or ""
end
e.write = function(a, a, t)
    i.writefile(o, t:gsub("\r\n", "\n"))
end
e.remove = function(e, e, e)
    i.writefile(o, "")
end
t = a:section(TypedSection, "macbind", translate("名单设置"), translate("如果是黑名单模式，列表中的客户端将被禁止连接到互联网；白名单模式表示仅有列表中的客户端可以连接到互联网。"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true
e = t:option(Flag, "enable", translate("开启控制"))
e.rmempty = false
e = t:option(Value, "macaddr", translate("MAC地址"))
e.rmempty = true
local t = n.net.mac_hints()
local o = {}
for t, e in pairs(t) do
    o[e[1]:lower()] = e[2]
end
luci.ip.neighbors({ family = 4 }, function(t)
    if t.reachable then
        local a
        if o[t.mac] then
            a = o[t.mac]
        else
            a = '-'
        end
        e:value(t.mac, "%s (%s,%s)" % { t.dest:string(), t.mac, a })
    end
end)
return a
