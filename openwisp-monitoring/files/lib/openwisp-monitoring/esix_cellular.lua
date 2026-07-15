-- ESIX Cellular monitoring module
-- Collects cellular modem information, signal data, and GNSS data
-- Equivalent to ESIX-CELLULAR-MIB SNMP implementation

local ubus_lib = require('ubus')
local cjson = require('cjson')
local uci = require('uci')
local utils = require('openwisp-monitoring.utils')
local uci_cursor = uci.cursor()

local esix_cellular = {}

local function modem_ubus_name(modem)
    return 'modem_' .. modem.name
end

local function ubus_call_modem(ubus, modem, method, params)
    return ubus:call(modem_ubus_name(modem), method, params or {})
end

local function to_number(value)
    local values = {}

    if value == nil then
        return nil
    end
    if type(value) == 'number' then
        if value == -32768 then
            return nil
        end
        return value
    end
    if type(value) ~= 'string' then
        return nil
    end

    value = value:gsub('\r', '')
    for line in value:gmatch('[^\n]+') do
        line = line:match('^%s*(.-)%s*$')
        if line ~= '' and line ~= '--' and line ~= '-' then
            local num = tonumber(line)
            if num ~= nil and num ~= -32768 then
                table.insert(values, num)
            end
        end
    end

    if #values == 0 then
        return nil
    end
    return values[1]
end

local function pick_best_signal(values)
    local best = nil
    for _, value in ipairs(values) do
        if type(value) == 'string' and value:find('\n', 1, true) then
            for line in value:gmatch('[^\n]+') do
                local num = to_number(line)
                if num ~= nil then
                    if best == nil or num > best then
                        best = num
                    end
                end
            end
        else
            local num = to_number(value)
            if num ~= nil then
                if best == nil or num > best then
                    best = num
                end
            end
        end
    end
    return best
end

local function pick_preferred_value(values)
    for _, value in ipairs(values) do
        if type(value) == 'string' then
            value = value:gsub('\r', '')
            local picked = nil
            for line in value:gmatch('[^\n]+') do
                line = line:match('^%s*(.-)%s*$')
                if line ~= '' then
                    picked = line
                end
            end
            if picked ~= nil then
                return picked
            end
        elseif value ~= nil then
            return value
        end
    end
    return nil
end

local function compact_values(...)
    local values = {}
    for i = 1, select('#', ...) do
        local value = select(i, ...)
        if value ~= nil then
            table.insert(values, value)
        end
    end
    return values
end

local function get_serving_cells(serving)
    local cells = {}
    if type(serving) ~= 'table' then
        return cells
    end

    if type(serving.mode) == 'string' and serving.mode:find('NR5G', 1, true) then
        if type(serving.nr5g) == 'table' then
            table.insert(cells, serving.nr5g)
        end
        if type(serving.lte) == 'table' then
            table.insert(cells, serving.lte)
        end
    else
        if type(serving.lte) == 'table' then
            table.insert(cells, serving.lte)
        end
        if type(serving.nr5g) == 'table' then
            table.insert(cells, serving.nr5g)
        end
    end

    table.insert(cells, serving)
    return cells
end

local function parse_json_table(value)
    if type(value) == 'table' then
        return value
    end
    if type(value) ~= 'string' or value == '' then
        return nil
    end

    local success, decoded = pcall(cjson.decode, value)
    if not success or type(decoded) ~= 'table' then
        return nil
    end
    return decoded
end

local function parse_latency_ms(value)
    if type(value) == 'number' then
        return value
    end
    if type(value) ~= 'string' then
        return nil
    end

    local latency = value:match('([%-%d%.]+)%s*ms')
    if latency == nil then
        latency = value:match('([%-%d%.]+)')
    end
    return tonumber(latency)
end

local function get_modem_ping_dest(modem)
    if type(modem) ~= 'table' or type(modem.name) ~= 'string' or modem.name == '' then
        return nil
    end

    local addrs = {}
    if uci_cursor and type(uci_cursor.get_list) == 'function' then
        local success, result = pcall(function()
            return uci_cursor.get_list('modem', modem.name, 'sim_ping_addrs')
        end)
        if success and type(result) == 'table' then
            addrs = result
        end
    end

    for _, addr in ipairs(addrs) do
        if type(addr) == 'string' then
            addr = addr:match('^%s*(.-)%s*$')
            if addr ~= '' then
                return addr
            end
        end
    end

    if uci_cursor and type(uci_cursor.get) == 'function' then
        local success, result = pcall(function()
            return uci_cursor.get('modem', modem.name, 'sim_ping_addrs')
        end)
        if success and type(result) == 'string' then
            result = result:match('^%s*(.-)%s*$')
            if result ~= '' then
                return result
            end
        end
    end

    return nil
end

local function normalize_ping_signals(raw_signals)
    local signals = {}
    if type(raw_signals) ~= 'table' then
        return signals
    end

    local candidates = raw_signals
    if raw_signals[1] == nil and (
        raw_signals.mode ~= nil or raw_signals.band ~= nil or
        raw_signals.channel ~= nil or raw_signals.rsrp ~= nil or
        raw_signals.rsrq ~= nil or raw_signals.sinr ~= nil
    ) then
        candidates = {raw_signals}
    end

    for index, signal in ipairs(candidates) do
        if type(signal) == 'table' then
            local normalized_signal = {
                index = index,
                mode = pick_preferred_value(compact_values(signal.mode)),
                band = pick_preferred_value(compact_values(signal.band)),
                channel = pick_preferred_value(compact_values(signal.channel)),
                rsrp = to_number(signal.rsrp),
                rsrq = to_number(signal.rsrq),
                sinr = to_number(signal.sinr)
            }
            if normalized_signal.mode ~= nil or normalized_signal.band ~= nil or
                normalized_signal.channel ~= nil or normalized_signal.rsrp ~= nil or
                normalized_signal.rsrq ~= nil or normalized_signal.sinr ~= nil then
                table.insert(signals, normalized_signal)
            end
        end
    end

    return signals
end

local function pick_primary_ping_signal(signals)
    for _, signal in ipairs(signals) do
        if signal.rsrp ~= nil or signal.rsrq ~= nil or signal.sinr ~= nil then
            return signal
        end
    end
    return signals[1] or {}
end

local function is_ping_monitor_enabled(ping_monitor)
    if type(ping_monitor) ~= 'table' then
        return true
    end

    if ping_monitor.enable ~= nil then
        return ping_monitor.enable == true or tonumber(ping_monitor.enable) == 1
    end

    if ping_monitor.disable ~= nil then
        if ping_monitor.disable == false then
            return true
        end

        local disabled = tonumber(ping_monitor.disable)
        if disabled ~= nil then
            return disabled ~= 1
        end
    end

    return true
end

local function list_ping_interfaces(ubus, modem)
    local ping_interfaces = {}
    local success, result = pcall(function()
        return ubus_call_modem(ubus, modem, 'get_interfaces')
    end)

    if not success or type(result) ~= 'table' then
        return ping_interfaces
    end

    local interfaces = parse_json_table(result.interfaces)
    if type(interfaces) ~= 'table' then
        return ping_interfaces
    end

    for _, interface in ipairs(interfaces) do
        local ping_monitor = interface.ping_monitor or {}
        local enabled = is_ping_monitor_enabled(ping_monitor)

        if enabled and type(interface.name) == 'string' and interface.name ~= '' then
            table.insert(ping_interfaces, interface)
        end
    end

    return ping_interfaces
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

    table.sort(modems, function(a, b)
        return tostring(a.index) < tostring(b.index)
    end)
    
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
        signal_data.mode = nil
        signal_data.network_state = nil
        signal_data.rssi = nil
        signal_data.sinr = nil
        signal_data.rsrp = nil
        signal_data.rsrq = nil
        signal_data.band = nil
        signal_data.plmn = nil
        signal_data.pci = nil
        signal_data.cell_id = nil
        
        local network_success, network_result = pcall(function()
            return ubus_call_modem(ubus, modem, 'get_network_info')
        end)
        local signal_success, signal_result = pcall(function()
            return ubus_call_modem(ubus, modem, 'get_signal_info')
        end)

        if network_success and network_result then
            local network_info = network_result.network_info
            local serving = network_result.serving_cell
            local serving_cells = get_serving_cells(serving)

            if serving then
                signal_data.mode = serving.mode or signal_data.mode
                signal_data.network_state = serving.state or signal_data.network_state
                signal_data.cell_id = pick_preferred_value(compact_values(
                    serving.cellid,
                    serving.cell_id,
                    serving.lte and serving.lte.cellid,
                    serving.lte and serving.lte.cell_id,
                    serving.nr5g and serving.nr5g.cellid,
                    serving.nr5g and serving.nr5g.cell_id
                )) or signal_data.cell_id
                signal_data.pci = pick_best_signal(compact_values(
                    serving.pcid,
                    serving.pci,
                    serving.nr5g and serving.nr5g.pcid,
                    serving.nr5g and serving.nr5g.pci,
                    serving.lte and serving.lte.pcid,
                    serving.lte and serving.lte.pci
                )) or signal_data.pci
                signal_data.band = pick_preferred_value(compact_values(
                    serving.nr5g and serving.nr5g.band,
                    serving.lte and serving.lte.band,
                    serving.band
                )) or signal_data.band
                signal_data.rsrp = pick_best_signal(compact_values(
                    serving.rsrp,
                    serving.nr5g and serving.nr5g.rsrp,
                    serving.lte and serving.lte.rsrp
                )) or signal_data.rsrp
                signal_data.rsrq = pick_best_signal(compact_values(
                    serving.rsrq,
                    serving.nr5g and serving.nr5g.rsrq,
                    serving.lte and serving.lte.rsrq
                )) or signal_data.rsrq
                signal_data.sinr = pick_best_signal(compact_values(
                    serving.sinr,
                    serving.nr5g and serving.nr5g.sinr,
                    serving.lte and serving.lte.sinr
                )) or signal_data.sinr
                signal_data.rssi = pick_best_signal(compact_values(
                    serving.rssi,
                    serving.lte and serving.lte.rssi,
                    serving.nr5g and serving.nr5g.rssi
                )) or signal_data.rssi
            end

            if network_info then
                if signal_data.mode == nil and network_info.access_tech then
                    signal_data.mode = pick_preferred_value(compact_values(
                        network_info.access_tech
                    )) or signal_data.mode
                end
                if signal_data.band == nil and network_info.band then
                    signal_data.band = pick_preferred_value(compact_values(
                        network_info.band
                    )) or signal_data.band
                end
                if network_info.operator and network_info.operator ~= '' then
                    signal_data.plmn = to_number(network_info.operator) or signal_data.plmn
                end
            end

            if signal_data.plmn == nil and serving and serving.mcc and serving.mnc then
                signal_data.plmn = tonumber(serving.mcc .. serving.mnc) or signal_data.plmn
            elseif signal_data.plmn == nil then
                for _, cell in ipairs(serving_cells or {}) do
                    if cell.mcc and cell.mnc then
                        signal_data.plmn = tonumber(cell.mcc .. cell.mnc) or signal_data.plmn
                        if signal_data.plmn ~= nil then
                            break
                        end
                    end
                end
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

        table.insert(signal_info, signal_data)
    end
    
    if ubus.close then
        ubus:close()
    end
    return signal_info
end

function esix_cellular.get_ping_info()
    local ubus = get_ubus_connection()
    if not ubus then
        return {}
    end

    local modems = list_modems()
    local ping_info = {}

    for _, modem in ipairs(modems) do
        local ping_interfaces = list_ping_interfaces(ubus, modem)

        for _, interface in ipairs(ping_interfaces) do
            local success, result = pcall(function()
                return ubus:call('modem', 'get_ping_detected', {
                    modem_name = modem.name,
                    interface = interface.name
                })
            end)

            if success and type(result) == 'table' then
                local ping_detected = result.results and result.results.pingDetected or
                    result.pingDetected
                local detected_time = to_number(result.results and result.results.time) or 0

                if type(ping_detected) == 'table' then
                    local latency = parse_latency_ms(ping_detected.latency)
                    local interface_dest = type(interface.ping_monitor) == 'table' and
                        interface.ping_monitor.dest or nil
                    local dest = pick_preferred_value(compact_values(
                        ping_detected.dest,
                        interface_dest,
                        get_modem_ping_dest(modem)
                    )) or ''
                    local signals = normalize_ping_signals(ping_detected.signal)
                    local signal = pick_primary_ping_signal(signals)
                    local record = {
                        id = modem.index,
                        modem = modem.name,
                        interface = interface.name,
                        dest = dest,
                        detected_time = detected_time,
                        carrier = pick_preferred_value(compact_values(
                            ping_detected.carrier
                        )),
                        mcc = pick_preferred_value(compact_values(
                            ping_detected.mcc
                        )),
                        mnc = pick_preferred_value(compact_values(
                            ping_detected.mnc
                        )),
                        tac = pick_preferred_value(compact_values(
                            ping_detected.tac
                        )),
                        cell_id = pick_preferred_value(compact_values(
                            ping_detected.cell_id,
                            ping_detected.cellid
                        )),
                        mode = pick_preferred_value(compact_values(signal.mode)),
                        band = pick_preferred_value(compact_values(signal.band)),
                        channel = pick_preferred_value(compact_values(
                            signal.channel
                        )),
                        rsrp = to_number(signal.rsrp),
                        rsrq = to_number(signal.rsrq),
                        sinr = to_number(signal.sinr)
                    }
                    if latency ~= nil then
                        record.latency = latency
                    end
                    if #signals > 0 then
                        record.signals = signals
                    end
                    table.insert(ping_info, record)
                end
            end
        end
    end

    if ubus.close then
        ubus:close()
    end
    return ping_info
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
        gnss_data.hdop = 0.0
        gnss_data.cog = 0.0
        gnss_data.spkm = 0.0
        
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
                gnss_data.nsat = to_number(data.NSAT or data.nsat) or gnss_data.nsat
                gnss_data.hdop = to_number(data.HDOP or data.hdop) or gnss_data.hdop
                gnss_data.cog = to_number(data.COG or data.cog) or gnss_data.cog
                gnss_data.spkm = to_number(data.SPKM or data.spkm) or gnss_data.spkm
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
        ping_info = esix_cellular.get_ping_info(),
        gnss_info = esix_cellular.get_gnss_info()
    }
end

return esix_cellular
