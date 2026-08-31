-- 探针:确认 libmpv(不是 mpv CLI)真的跑用户 Lua 脚本,且 osd-overlay 可用
local msg = require 'mp.msg'
msg.info("LUAPROBE_SCRIPT_RAN")
local ok, err = pcall(function()
  local o = mp.create_osd_overlay("ass-events")
  o.res_x, o.res_y = 1280, 720
  o.data = [[{\an7\pos(40,40)\fs48\c&H00FF00&}LUAPROBE_OVERLAY]]
  o:update()
end)
msg.info("LUAPROBE_OSD_OVERLAY=" .. tostring(ok) .. " " .. tostring(err))
mp.set_property("user-data/luaprobe", ok and "overlay-ok" or "overlay-fail")
-- 顺带看看脚本能不能自己发网络请求(uosc_danmaku 靠 curl 子进程拉弹幕)
local sp = mp.command_native({name="subprocess", args={"cmd","/c","echo","LUAPROBE_SUBPROCESS"},
                              capture_stdout=true, playback_only=false})
msg.info("LUAPROBE_SUBPROCESS_STATUS=" .. tostring(sp and sp.status))
