package.path = package.path ..
                 ";../files/lib/openwisp-monitoring/?.lua;../files/lib/?.lua"

local luaunit = require('luaunit')

local function reset_modules()
  package.loaded.esix_cellular = nil
  package.loaded.ubus = nil
  package.loaded.uci = nil
  package.loaded.io = nil
end

local function default_ubus_call(object, method, params)
  if object == 'uci' and method == 'get' then
    return {
      values = {
        wwan0 = {
          ['.type'] = 'modem',
          name = 'wwan0',
          device = 'wwan0',
          index = '1'
        }
      }
    }
  elseif object == 'modem_wwan0' and method == 'get_network_info' then
    return {
      network_info = {
        access_tech = 'FDD LTE\nTDD NR5G',
        operator = '45412\n45412',
        band = 'LTE BAND 3\nNR5G BAND 79'
      },
      serving_cell = {
        state = 'NOCONN',
        mode = 'NR5G-NSA',
        dual_connectivity = 'EN-DC',
        lte = {
          mcc = '454',
          mnc = '12',
          cellid = '1931066',
          pcid = '9',
          band = '3',
          rsrp = '-85',
          rsrq = '-14',
          rssi = '-54',
          sinr = '14'
        },
        nr5g = {
          mcc = '454',
          mnc = '12',
          pcid = '767',
          band = '79',
          rsrp = '-88',
          rsrq = '-10',
          sinr = '17'
        }
      }
    }
  elseif object == 'modem_wwan0' and method == 'get_signal_info' then
    return {
      rsrp = {
        rsrp1 = '-85\n-92',
        rsrp2 = '-87\n-88',
        rsrp3 = '-32768\n-92',
        rsrp4 = '-32768\n-93'
      },
      rsrq = {
        rsrq1 = '-11\n-10',
        rsrq2 = '-11\n-10',
        rsrq3 = '-32768\n-10',
        rsrq4 = '-32768\n-10'
      },
      sinr = {
        sinr1 = '14\n17',
        sinr2 = '0\n15',
        sinr3 = '-32768\n10',
        sinr4 = '-32768\n9'
      }
    }
  elseif object == 'modem_wwan0' and method == 'get_interfaces' then
    return {
      interfaces = '[{"name":"wwan0_1","ping_monitor":{"enable":1,"dest":"8.8.8.8"}}]'
    }
  elseif object == 'modem' and method == 'get_ping_detected' and params and
      params.interface == 'wwan0_1' then
    return {
      results = {
        time = 1775636302000,
        pingDetected = {
          device = 'wwan0_1',
          dest = '8.8.8.8',
          cellid = '28317002',
          carrier = 'CHN-UNICOM',
          mcc = '460',
          mnc = '1',
          tac = '829400',
          signal = {
            {
              mode = 'NR5G-SA',
              band = '78',
              channel = '627264',
              rsrp = '-99',
              sinr = '10',
              rsrq = -10
            }
          },
          latency = '659ms'
        }
      }
    }
  end

  return {}
end

local function set_ubus_handler(handler)
  package.loaded.ubus = {
    connect = function()
      return {
        call = function(_, object, method, params)
          return handler(object, method, params)
        end,
        close = function() end
      }
    end
  }
end

TestEsixCellular = {
  setUp = function()
    reset_modules()
    set_ubus_handler(default_ubus_call)
  end,
  tearDown = function()
    reset_modules()
  end
}

function TestEsixCellular.test_get_signal_info_handles_nsa_payload()
  local esix_cellular = require('esix_cellular')
  local signal_info = esix_cellular.get_signal_info()

  luaunit.assertEquals(#signal_info, 1)
  luaunit.assertEquals(signal_info[1].modem, 'wwan0')
  luaunit.assertEquals(signal_info[1].mode, 'NR5G-NSA')
  luaunit.assertEquals(signal_info[1].network_state, 'NOCONN')
  luaunit.assertEquals(signal_info[1].cell_id, '1931066')
  luaunit.assertEquals(signal_info[1].pci, 767)
  luaunit.assertEquals(signal_info[1].plmn, 45412)
  luaunit.assertEquals(signal_info[1].band, '79')
  luaunit.assertEquals(signal_info[1].rssi, -54)
  luaunit.assertEquals(signal_info[1].rsrp, -85)
  luaunit.assertEquals(signal_info[1].rsrq, -10)
  luaunit.assertEquals(signal_info[1].sinr, 17)
end

function TestEsixCellular.test_get_ping_info_collects_enabled_interface_latency()
  local esix_cellular = require('esix_cellular')
  local ping_info = esix_cellular.get_ping_info()

  luaunit.assertEquals(#ping_info, 1)
  luaunit.assertEquals(ping_info[1].modem, 'wwan0')
  luaunit.assertEquals(ping_info[1].interface, 'wwan0_1')
  luaunit.assertEquals(ping_info[1].dest, '8.8.8.8')
  luaunit.assertEquals(ping_info[1].latency, 659)
  luaunit.assertEquals(ping_info[1].detected_time, 1775636302000)
  luaunit.assertEquals(ping_info[1].carrier, 'CHN-UNICOM')
  luaunit.assertEquals(ping_info[1].cell_id, '28317002')
  luaunit.assertEquals(ping_info[1].mode, 'NR5G-SA')
  luaunit.assertEquals(ping_info[1].band, '78')
  luaunit.assertEquals(ping_info[1].channel, '627264')
  luaunit.assertEquals(ping_info[1].rsrp, -99)
  luaunit.assertEquals(ping_info[1].rsrq, -10)
  luaunit.assertEquals(ping_info[1].sinr, 10)
end

function TestEsixCellular.test_get_ping_info_supports_multiple_interfaces()
  set_ubus_handler(function(object, method, params)
    if object == 'modem_wwan0' and method == 'get_interfaces' then
      return {
        interfaces =
          '[{"name":"wwan0_1","ping_monitor":{"enable":1,"dest":"8.8.8.8"}},' ..
          '{"name":"wwan0_2","ping_monitor":{"enable":1,"dest":"1.1.1.1"}}]'
      }
    elseif object == 'modem' and method == 'get_ping_detected' and params then
      return {
        results = {
          time = 1775636302000,
          pingDetected = {
            dest = params.interface == 'wwan0_1' and '8.8.8.8' or '1.1.1.1',
            cellid = params.interface == 'wwan0_1' and '28317002' or '28317003',
            latency = params.interface == 'wwan0_1' and '659ms' or '101ms',
            signal = {
              {
                mode = 'NR5G-SA',
                band = '78',
                channel = params.interface == 'wwan0_1' and '627264' or '627265'
              }
            }
          }
        }
      }
    end

    return default_ubus_call(object, method, params)
  end)

  local esix_cellular = require('esix_cellular')
  local ping_info = esix_cellular.get_ping_info()

  luaunit.assertEquals(#ping_info, 2)
  luaunit.assertEquals(ping_info[1].interface, 'wwan0_1')
  luaunit.assertEquals(ping_info[1].latency, 659)
  luaunit.assertEquals(ping_info[2].interface, 'wwan0_2')
  luaunit.assertEquals(ping_info[2].dest, '1.1.1.1')
  luaunit.assertEquals(ping_info[2].latency, 101)
end

function TestEsixCellular.test_get_ping_info_skips_disabled_interfaces()
  local ping_detected_calls = 0

  set_ubus_handler(function(object, method, params)
    if object == 'modem_wwan0' and method == 'get_interfaces' then
      return {
        interfaces = '[{"name":"wwan0_1","ping_monitor":{"enable":0,"dest":"8.8.8.8"}}]'
      }
    elseif object == 'modem' and method == 'get_ping_detected' then
      ping_detected_calls = ping_detected_calls + 1
    end

    return default_ubus_call(object, method, params)
  end)

  local esix_cellular = require('esix_cellular')
  local ping_info = esix_cellular.get_ping_info()

  luaunit.assertEquals(#ping_info, 0)
  luaunit.assertEquals(ping_detected_calls, 0)
end

function TestEsixCellular.test_get_ping_info_skips_invalid_or_missing_latency()
  set_ubus_handler(function(object, method, params)
    if object == 'modem_wwan0' and method == 'get_interfaces' then
      return {
        interfaces =
          '[{"name":"wwan0_1","ping_monitor":{"enable":1,"dest":"8.8.8.8"}},' ..
          '{"name":"wwan0_2","ping_monitor":{"enable":1,"dest":"1.1.1.1"}}]'
      }
    elseif object == 'modem' and method == 'get_ping_detected' and params then
      return {
        results = {
          time = 1775636302000,
          pingDetected = {
            dest = params.interface == 'wwan0_1' and '8.8.8.8' or '1.1.1.1',
            latency = params.interface == 'wwan0_1' and 'bad-value' or nil
          }
        }
      }
    end

    return default_ubus_call(object, method, params)
  end)

  local esix_cellular = require('esix_cellular')
  local ping_info = esix_cellular.get_ping_info()

  luaunit.assertEquals(#ping_info, 0)
end

os.exit(luaunit.LuaUnit.run())
