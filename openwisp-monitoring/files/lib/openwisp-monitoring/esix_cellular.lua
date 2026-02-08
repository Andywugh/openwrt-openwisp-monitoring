-- ESIX Cellular monitoring module
-- Collects cellular modem information, signal data, and GNSS data
-- Equivalent to ESIX-CELLULAR-MIB SNMP implementation

local ubus_lib = require('ubus')
local cjson = require('cjson')
local utils = require('openwisp-monitoring.utils')

local esix_cellular = {}

local function modem_ubus_name(modem)
    return 'modem_' .. modem.name
end

local function ubus_call_modem(ubus, modem, method, params)
    return ubus:call(modem_ubus_name(modem), method, params or {})
end

local function to_number(value)
    if value == nil then
        return nil
    end
    if type(value) == 'number' then
        return value
    end
    if type(value) ~= 'string' then
        return nil
    end
    if value == '' or value == '--' or value == '-' then
        return nil
    end
    local num = tonumber(value)
    if num == -32768 then
        return nil
    end
    return num
end

local function pick_best_signal(values)
    local best = nil
    for _, value in ipairs(values) do
        local num = to_number(value)
        if num ~= nil then
            if best == nil or num > best then
                best = num
            end
        end
    end
    return best
end

-- Connect to ubus
local function get_ubus_connection()
    local ubus = ubus_lib.connect()
    if not ubus then
        return nil
    end
    return ubus
end

-- List available modems from UCI configuration
local function list_modems()
    local ubus = get_ubus_connection()
    if not ubus then
        return {}
    end
    
    local modems = {}
    local uci_data = ubus:call('uci', 'get', {config='modem'})
    
    if uci_data and uci_data.values then
        for section, data in pairs(uci_data.values) do
            if data['.type'] == 'modem' then
                local modem_index = data.index or section
                local modem_device = data.device or section
                
                table.insert(modems, {
                    name = section,
                    device = modem_device,
                    index = modem_index
                })
            end
        end
    end
    
    if ubus.close then
        ubus:close()
    end
    return modems
end

-- Get modem information (equivalent to cellularModemInfoTable)
function esix_cellular.get_modem_info()
    local ubus = get_ubus_connection()
    if not ubus then
        return {}
    end
    
    local modems = list_modems()
    local modem_info = {}
    
    for _, modem in ipairs(modems) do
        local info_data = {}
        info_data.id = modem.index
        info_data.name = modem.name
        info_data.imei = "0"
        info_data.revision = "N/A"
        info_data.sim_status = "N/A"
        info_data.sim_slot = 1
        info_data.iccid = "0"
        info_data.imsi = "0"
        
        -- Get basic and SIM info via ubus (new modem RPCD service)
        local basic_success, basic_result = pcall(function()
            return ubus_call_modem(ubus, modem, 'get_basic_info')
        end)
        if basic_success and basic_result and basic_result.basic_info then
            local basic = basic_result.basic_info
            info_data.imei = basic.imei or info_data.imei
            info_data.revision = basic.revision or basic.firmware or info_data.revision
            info_data.iccid = basic.iccid or info_data.iccid
            info_data.imsi = basic.imsi or info_data.imsi
        end

        local sim_success, sim_result = pcall(function()
            return ubus_call_modem(ubus, modem, 'get_sim_info')
        end)
        if sim_success and sim_result then
            if sim_result.sim_status then
                if sim_result.sim_status.inserted and sim_result.sim_status.inserted ~= '' then
                    info_data.sim_status = sim_result.sim_status.inserted
                elseif sim_result.sim_status.enable and sim_result.sim_status.enable ~= '' then
                    info_data.sim_status = sim_result.sim_status.enable
                end
            end
            if sim_result.simpin and sim_result.simpin.status and
                sim_result.simpin.status ~= '' then
                info_data.sim_status = sim_result.simpin.status
            end
            if sim_result.sim_slot and sim_result.sim_slot.slot then
                info_data.sim_slot = tonumber(sim_result.sim_slot.slot) or info_data.sim_slot
            end
        end
        
        table.insert(modem_info, info_data)
    end
    
    if ubus.close then
        ubus:close()
    end
    return modem_info
end

-- Get signal information (equivalent to cellularSignalInfoTable)
function esix_cellular.get_signal_info()
    local ubus = get_ubus_connection()
    if not ubus then
        return {}
    end
    
    local modems = list_modems()
    local signal_info = {}
    
    for _, modem in ipairs(modems) do
        local signal_data = {}
        signal_data.id = modem.index
        signal_data.modem = modem.name
        signal_data.mode = "N/A"
        signal_data.network_state = "N/A"
        signal_data.rssi = nil
        signal_data.sinr = nil
        signal_data.rsrp = nil
        signal_data.rsrq = nil
        signal_data.band = "0"
        signal_data.plmn = 0
        signal_data.pci = 0
        signal_data.cell_id = "N/A"
        
        local network_success, network_result = pcall(function()
            return ubus_call_modem(ubus, modem, 'get_network_info')
        end)
        local signal_success, signal_result = pcall(function()
            return ubus_call_modem(ubus, modem, 'get_signal_info')
        end)

        if network_success and network_result then
            local network_info = network_result.network_info
            local serving = network_result.serving_cell

            if serving then
                signal_data.mode = serving.mode or signal_data.mode
                signal_data.network_state = serving.state or signal_data.network_state
                signal_data.cell_id = serving.cellid or serving.cell_id or signal_data.cell_id
                signal_data.pci = to_number(serving.pcid) or signal_data.pci
                signal_data.band = serving.band or signal_data.band
                signal_data.rsrp = to_number(serving.rsrp) or signal_data.rsrp
                signal_data.rsrq = to_number(serving.rsrq) or signal_data.rsrq
                signal_data.sinr = to_number(serving.sinr) or signal_data.sinr
                signal_data.rssi = to_number(serving.rssi) or signal_data.rssi
            end

            if network_info then
                if signal_data.mode == "N/A" and network_info.access_tech then
                    signal_data.mode = network_info.access_tech
                end
                if signal_data.band == "0" and network_info.band then
                    signal_data.band = network_info.band
                end
                if network_info.operator and network_info.operator ~= '' then
                    signal_data.plmn = tonumber(network_info.operator) or signal_data.plmn
                end
            end

            if signal_data.plmn == 0 and serving and serving.mcc and serving.mnc then
                signal_data.plmn = tonumber(serving.mcc .. serving.mnc) or signal_data.plmn
            end
        end

        if signal_success and signal_result then
            if signal_data.rsrp == nil and signal_result.rsrp then
                signal_data.rsrp = pick_best_signal({
                    signal_result.rsrp.rsrp1,
                    signal_result.rsrp.rsrp2,
                    signal_result.rsrp.rsrp3,
                    signal_result.rsrp.rsrp4
                })
            end
            if signal_data.rsrq == nil and signal_result.rsrq then
                signal_data.rsrq = pick_best_signal({
                    signal_result.rsrq.rsrq1,
                    signal_result.rsrq.rsrq2,
                    signal_result.rsrq.rsrq3,
                    signal_result.rsrq.rsrq4
                })
            end
            if signal_data.sinr == nil and signal_result.sinr then
                signal_data.sinr = pick_best_signal({
                    signal_result.sinr.sinr1,
                    signal_result.sinr.sinr2,
                    signal_result.sinr.sinr3,
                    signal_result.sinr.sinr4
                })
            end
        end

        signal_data.rssi = signal_data.rssi or 0
        signal_data.sinr = signal_data.sinr or 0
        signal_data.rsrp = signal_data.rsrp or 0
        signal_data.rsrq = signal_data.rsrq or 0
        
        table.insert(signal_info, signal_data)
    end
    
    if ubus.close then
        ubus:close()
    end
    return signal_info
end

-- Get GNSS information (equivalent to cellularGnssInfoTable)
function esix_cellular.get_gnss_info()
    local ubus = get_ubus_connection()
    if not ubus then
        return {}
    end
    
    local modems = list_modems()
    local gnss_info = {}
    
    for _, modem in ipairs(modems) do
        local gnss_data = {}
        gnss_data.id = modem.index
        gnss_data.modem = modem.name
        gnss_data.longitude = "0"
        gnss_data.latitude = "0"
        gnss_data.altitude = "0"
        gnss_data.utc_timestamp = "1999-11-30T00:00:00Z"
        gnss_data.nsat = 0
        gnss_data.hdop = 0
        gnss_data.cog = 0
        gnss_data.spkm = 0
        
        -- Get GNSS data via ubus (new modem RPCD service)
        local success, result = pcall(function()
            return ubus_call_modem(ubus, modem, 'get_gps_location')
        end)
        if success and result then
            local data = result.result or result.gps_location or result
            if data then
                gnss_data.longitude = data.LON or data.longitude or gnss_data.longitude
                gnss_data.latitude = data.LAT or data.latitude or gnss_data.latitude
                gnss_data.altitude = data.ALT or data.altitude or gnss_data.altitude
                gnss_data.utc_timestamp = data.DATE or data.date or gnss_data.utc_timestamp
                gnss_data.nsat = tonumber(data.NSAT or data.nsat) or gnss_data.nsat
                gnss_data.hdop = tonumber(data.HDOP or data.hdop) or gnss_data.hdop
                gnss_data.cog = tonumber(data.COG or data.cog) or gnss_data.cog
                gnss_data.spkm = tonumber(data.SPKM or data.spkm) or gnss_data.spkm
            end
        end
        
        table.insert(gnss_info, gnss_data)
    end
    
    if ubus.close then
        ubus:close()
    end
    return gnss_info
end

-- Get all ESIX cellular data in one call
function esix_cellular.get_all_data()
    return {
        modem_info = esix_cellular.get_modem_info(),
        signal_info = esix_cellular.get_signal_info(),
        gnss_info = esix_cellular.get_gnss_info()
    }
end

return esix_cellular
