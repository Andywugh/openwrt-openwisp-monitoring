package.path = package.path ..
                 ";../files/lib/openwisp-monitoring/?.lua;../files/sbin/?.lua"

local cjson = require("cjson")
local luaunit = require('luaunit')
local wifi_functions = require('wifi')
local wifi_data = require('test_files/wireless_data')

local function find_interface(netjson, name)
  for _, iface in ipairs(netjson.interfaces or {}) do
    if iface.name == name then return iface end
  end
  return nil
end

local function copy_clients(clients)
  local copy = {}
  for i, client in ipairs(clients) do
    copy[i] = client
  end
  return copy
end

local function sort_clients_by_mac(clients)
  table.sort(clients, function(a, b) return a.mac < b.mac end)
  return clients
end

TestWifi = {setUp = function() end, tearDown = function() end}

TestNetJSON = {
  setUp = function()
    local env = require('basic_env')
    package.loaded.io = env.io
    package.loaded.uci = env.uci
    package.loaded.nixio = {
      getifaddrs = function() return require('test_files/nixio_data') end
    }
    package.loaded.ubus = {
      connect = function()
        return {
          call = function(...)
            local arg = {...}
            if arg[2] == 'system' and arg[3] == 'board' then
              return {hostname = "08-00-27-56-92-F5"}
            elseif arg[2] == 'system' and arg[3] == 'info' then
              return {memory = nil, local_time = nil, uptime = nil, swap = nil}
            elseif arg[2] == 'network.device' and arg[3] == 'status' then
              return require('test_files/network_data').wireless
            elseif arg[2] == 'network.wireless' and arg[3] == 'status' then
              return wifi_data.wireless_status
            elseif arg[2] == 'network.interface' and arg[3] == 'dump' then
              local f = require('test_files/interface_data')
              return f.interface_data
            elseif arg[2] == 'iwinfo' and arg[3] == 'info' then
              if arg[4].device == "wlan0" then
                return wifi_data.wlan0_iwinfo
              elseif arg[4].device == "wlan1" then
                return wifi_data.wlan1_iwinfo
              elseif arg[4].device == "wlan2" then
                return wifi_data.wlan2_iwinfo
              elseif arg[4].device == "mesh0" then
                return wifi_data.mesh0_iwinfo
              elseif arg[4].device == "mesh1" then
                return wifi_data.mesh1_iwinfo
              end
            elseif arg[2] == 'iwinfo' and arg[3] == 'assoclist' then
              if arg[4].device == "wlan0" then
                return wifi_data.wlan0_clients
              elseif arg[4].device == "mesh0" then
                return wifi_data.mesh0_clients
              elseif arg[4].device == "mesh1" then
                return wifi_data.mesh1_clients
              end
            else
              return {}
            end
          end
        }
      end
    }
  end,
  tearDown = function() end
}

function TestWifi.test_parse_hostapd_clients()
  local actual = wifi_functions.parse_hostapd_clients(wifi_data.wlan1_clients)
  local expected = wifi_data.parsed_clients
  luaunit.assertEquals(sort_clients_by_mac(copy_clients(actual)),
    sort_clients_by_mac(copy_clients(expected)))
  luaunit.assertEquals(wifi_functions.parse_hostapd_clients(wifi_data.wlan2_clients),
    nil)
end

function TestWifi.test_parse_iwinfo_clients()
  luaunit.assertEquals(wifi_functions.parse_iwinfo_clients(
    wifi_data.mesh0_clients.results), wifi_data.mesh0_parsed_clients)
  luaunit.assertEquals(wifi_functions.parse_iwinfo_clients(
    wifi_data.mesh1_clients.results), wifi_data.mesh1_parsed_clients)
end

function TestWifi.test_netjson_clients()
  -- testing hostapd clients
  local actual = wifi_functions.netjson_clients(wifi_data.wlan1_clients, false)
  local expected = wifi_data.parsed_clients
  luaunit.assertEquals(sort_clients_by_mac(copy_clients(actual)),
    sort_clients_by_mac(copy_clients(expected)))
  luaunit.assertEquals(wifi_functions.netjson_clients(wifi_data.wlan2_clients, false),
    nil)
  -- testing iwinfo clients
  luaunit.assertEquals(
    wifi_functions.netjson_clients(wifi_data.mesh0_clients.results, true),
    wifi_data.mesh0_parsed_clients)
  luaunit.assertEquals(
    wifi_functions.netjson_clients(wifi_data.mesh1_clients.results, true),
    wifi_data.mesh1_parsed_clients)
end

function TestWifi.test_needs_inversion()
  luaunit.assertFalse(wifi_functions.needs_inversion(wifi_data.wlan0_interface))
  luaunit.assertTrue(wifi_functions.needs_inversion(wifi_data.wlan1_interface))
end

function TestWifi.test_invert_rx_tx()
  local network_data = require('test_files/network_data')
  luaunit.assertNotNil(network_data)
  local interface = wifi_functions.invert_rx_tx(network_data.wlan1_stats)
  luaunit.assertEquals(interface.rx_bytes, 531596854)
  luaunit.assertEquals(interface.tx_bytes, 0)
  luaunit.assertEquals(interface.rx_packets, 2367515)
  luaunit.assertEquals(interface.tx_packets, 0)
end

function TestNetJSON.test_wifi_interfaces()
  local netjson_string = require('netjson-monitoring')
  local netjson = cjson.decode(netjson_string)
  local mesh0 = find_interface(netjson, "mesh0")
  local mesh1 = find_interface(netjson, "mesh1")
  local wlan0 = find_interface(netjson, "wlan0")
  local wlan1 = find_interface(netjson, "wlan1")
  luaunit.assertNotNil(mesh0)
  luaunit.assertNotNil(mesh1)
  luaunit.assertNotNil(wlan0)
  luaunit.assertNotNil(wlan1)
  luaunit.assertEquals(mesh0["wireless"]["signal"], -67)
  luaunit.assertEquals(mesh1["wireless"]["signal"], -76)
  luaunit.assertEquals(mesh0["wireless"]["ssid"], "meshID")
  luaunit.assertEquals(mesh1["wireless"]["ssid"], "meshID")
  luaunit.assertEquals(mesh0["wireless"]["tx_power"], 20)
  luaunit.assertEquals(mesh1["wireless"]["tx_power"], 20)
  luaunit.assertEquals(wlan0["wireless"]["tx_power"], 20)
  luaunit.assertEquals(wlan1["wireless"]["tx_power"], 20)
  luaunit.assertEquals(mesh0["wireless"]["clients"][1]["vht"], true)
  luaunit.assertEquals(mesh1["wireless"]["clients"][1]["vht"], false)
  luaunit.assertEquals(mesh1["wireless"]["frequency"], 5200)
  luaunit.assertEquals(wlan1["wireless"]["mode"], "access_point")
  luaunit.assertEquals(wlan0["wireless"]["mode"], "station")
  luaunit.assertEquals(wlan0["wireless"]["clients"][1]["mac"], "22:33:2F:9A:14:9D")
end

function TestNetJSON.test_wifi_interfaces_stats_include()
  local netjson_file = assert(loadfile('../files/sbin/netjson-monitoring.lua'))
  local netjson = cjson.decode(netjson_file('wlan0 wlan1 mesh1'))
  local mesh1 = find_interface(netjson, "mesh1")
  local wlan0 = find_interface(netjson, "wlan0")
  local wlan1 = find_interface(netjson, "wlan1")
  luaunit.assertNotNil(mesh1)
  luaunit.assertNotNil(wlan0)
  luaunit.assertNotNil(wlan1)
  luaunit.assertEquals(mesh1["wireless"]["channel"], 40)
  luaunit.assertEquals(mesh1["wireless"]["mode"], "802.11s")
  luaunit.assertEquals(wlan0["statistics"]["rx_packets"], 198)
  luaunit.assertEquals(wlan1["statistics"]["rx_packets"], 2367515)
  luaunit.assertEquals(wlan0["statistics"]["rx_bytes"], 25967)
  luaunit.assertEquals(wlan0["statistics"]["tx_bytes"], 531641723)
  luaunit.assertEquals(mesh1["statistics"]["tx_bytes"], 151599685066)
  luaunit.assertEquals(wlan0["statistics"]["tx_packets"], 2367747)
  luaunit.assertEquals(mesh1["statistics"]["tx_errors"], 0)
  luaunit.assertEquals(wlan1["statistics"]["tx_errors"], 0)
  luaunit.assertEquals(wlan0["statistics"]["tx_errors"], 0)
end

function TestNetJSON.test_wifi_interfaces_stats_include_htmode()
  local netjson_file = assert(loadfile('../files/sbin/netjson-monitoring.lua'))
  local netjson = cjson.decode(netjson_file('wlan0 wlan1 mesh1'))
  local wlan2 = find_interface(netjson, "wlan2")
  local mesh1 = find_interface(netjson, "mesh1")
  local wlan1 = find_interface(netjson, "wlan1")
  local mesh0 = find_interface(netjson, "mesh0")
  local wlan0 = find_interface(netjson, "wlan0")
  luaunit.assertNotNil(wlan2)
  luaunit.assertNotNil(mesh1)
  luaunit.assertNotNil(wlan1)
  luaunit.assertNotNil(mesh0)
  luaunit.assertNotNil(wlan0)
  luaunit.assertEquals(mesh1["wireless"]["htmode"], "VHT80")
  luaunit.assertEquals(wlan1["wireless"]["htmode"], "VHT80")
  luaunit.assertEquals(mesh0["wireless"]["htmode"], "HT20")
  luaunit.assertEquals(wlan0["wireless"]["htmode"], "HT20")
end

function TestNetJSON.test_wifi_interfaces_when_iwinfo_channel_empty()
  local netjson_file = assert(loadfile('../files/sbin/netjson-monitoring.lua'))
  local netjson = cjson.decode(netjson_file('wlan0 wlan1 wlan2 mesh1'))
  local wlan2 = find_interface(netjson, "wlan2")
  local mesh1 = find_interface(netjson, "mesh1")
  local wlan1 = find_interface(netjson, "wlan1")
  local mesh0 = find_interface(netjson, "mesh0")
  local wlan0 = find_interface(netjson, "wlan0")
  local wan = find_interface(netjson, "wan")
  luaunit.assertNotNil(wlan2)
  luaunit.assertEquals(wlan2["type"], "wireless")
  -- the `wireless` key should be missing when "iwinfo.channel" is `nil`
  luaunit.assertNil(wlan2["wireless"])
  luaunit.assertNotNil(mesh1)
  luaunit.assertIsTable(mesh1["wireless"])
  luaunit.assertNotNil(wan)
  luaunit.assertNotNil(wlan1)
  luaunit.assertIsTable(wlan1["wireless"])
  luaunit.assertNotNil(mesh0)
  luaunit.assertIsTable(mesh0["wireless"])
  luaunit.assertNotNil(wlan0)
  luaunit.assertIsTable(wlan0["wireless"])
end
os.exit(luaunit.LuaUnit.run())
