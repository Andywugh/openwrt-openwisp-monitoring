package.path = package.path ..
                 ";../files/lib/openwisp-monitoring/?.lua;../files/lib/?.lua"

local luaunit = require('luaunit')

local function reset_modules()
  package.loaded.esix_cellular = nil
  package.loaded.ubus = nil
  package.loaded.uci = nil
  package.loaded.io = nil
end

TestEsixCellular = {
  setUp = function()
    reset_modules()
    package.loaded.ubus = {
      connect = function()
        return {
          call = function(...)
            local arg = {...}
            if arg[2] == 'uci' and arg[3] == 'get' then
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
            elseif arg[2] == 'modem_wwan0' and arg[3] == 'get_network_info' then
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
            elseif arg[2] == 'modem_wwan0' and arg[3] == 'get_signal_info' then
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
            end
            return {}
          end,
          close = function() end
        }
      end
    }
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

os.exit(luaunit.LuaUnit.run())
