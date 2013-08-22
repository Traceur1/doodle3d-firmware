local utils = require('util.utils')
local log = require('util.logger')
local settings = require('util.settings')
local wifi = require('network.wlanconfig')
local uci = require('uci').cursor()

local M = {}
local reconf = {}
local wifi
local reloadSilent

M.WWW_CAPTIVE_PATH = '/usr/share/lua/wifibox/www'
M.WWW_CAPTIVE_INDICATOR = '/www/.wifibox-inplace'
M.WWW_RENAME_NAME = '/www-regular'



local function reloadBit(dlist, itemname)
	if dlist[itemname] == nil then dlist[itemname] = '' end
	if dlist[itemname] == '' then dlist[itemname] = 'r'
	elseif dlist[itemname] == 'c' then dlist[itemname] = 'b'
	end
end
local function commitBit(dlist, itemname)
	if dlist[itemname] == nil then dlist[itemname] = '' end
	if dlist[itemname] == '' then dlist[itemname] = 'c'
	elseif dlist[itemname] == 'r' then dlist[itemname] = 'b'
	end
end
local function bothBits(dlist, itemname) dlist[itemname] = 'b' end



function M.init(wifiInstance, reloadSilent)
	wifi = wifiInstance
	silent = reloadSilent or false
	return true
end

--- Switch configuration between AP and station modes
-- @param components	a table with components as keys with operations as values (add or remove)
-- Valid components (each with add and rm operation) are: apnet, staticaddr, dhcppool, wwwredir, dnsredir, wwwcaptive, natreflect.
-- and additionally: wifiiface/add, network/reload
function M.switchConfiguration(components)
	local dirtyList = {} -- laundry list, add config/script name as key with value c (commit), r (reload) or b (both)
	
	for k,v in pairs(components) do
		local fname = k .. '_' .. v
		if type(reconf[fname]) == 'function' then
			log:debug("reconfiguring component '" .. k .. "' (" .. v .. ")")
			reconf[fname](dirtyList)
		else
			log:warn("unknown component or action '" .. fname .. "' skipped")
		end
	end
	
	-- first run all commits, then perform reloads
	for k,v in pairs(dirtyList) do
		if v == 'c' or v == 'b' then M.commitComponent(k) end
	end
	for k,v in pairs(dirtyList) do
		if v == 'r' or v == 'b' then M.reloadComponent(k, silent) end
	end
end

function M.commitComponent(c)
	log:info("committing component '" .. c .. "'")
	uci:commit(c)
end

function M.reloadComponent(c, silent)
	log:info("reloading component '" .. c .. "'")
	if silent ~= nil and silent then os.execute('/etc/init.d/' .. c .. ' reload &> /dev/null')
	else os.execute('/etc/init.d/' .. c .. ' reload') end
end

function M.uciTableSet(config, section, options)
	for k, v in pairs(options) do uci:set(config, section, k, v) end
end



--[[ Issue '/etc/init.d/network reload' command ]]
function reconf.network_reload(dirtyList) reloadBit(dirtyList, 'network') end

--[[ Issue '/etc/init.d/wireless reload' command ]]
function reconf.wireless_reload(dirtyList) reloadBit(dirtyList, 'wireless') end

--[[ Issue '/etc/init.d/dnsmasq reload' command ]]
function reconf.dhcp_reload(dirtyList) reloadBit(dirtyList, 'dnsmasq') end

--[[ Add wlan interface declaration to /etc/config/network ]]
function reconf.wifiiface_add(dirtyList)
	uci:set('network', wifi.NET, 'interface')
	commitBit(dirtyList, 'network')
end


--[[ Add/remove access point network ]]
function reconf.apnet_add_noreload(dirtyList) reconf.apnet_add(dirtyList, true) end
function reconf.apnet_add(dirtyList, noReload)
	local ourSsid = wifi.getSubstitutedSsid(settings.get('network.ap.ssid'))
	local sname = nil
	uci:foreach('wireless', 'wifi-iface', function(s)
		if s.ssid == ourSsid then sname = s['.name']; return false end
	end)
	if sname == nil then sname = uci:add('wireless', 'wifi-iface') end
	
	M.uciTableSet('wireless', sname, {
		network = wifi.NET,
		ssid = ourSsid,
		encryption = 'none',
		device = 'radio0',
		mode = 'ap',
	})
	
	commitBit(dirtyList, 'wireless')
	if noReload == nil or noReload == false then reloadBit(dirtyList, 'network') end
end
function reconf.apnet_rm(dirtyList)
	local sname = nil
	uci:foreach('wireless', 'wifi-iface', function(s)
		if s.ssid == wifi.getSubstitutedSsid(settings.get('network.ap.ssid')) then sname = s['.name']; return false end
	end)
	if sname == nil then return log:info("AP network configuration does not exist, nothing to remove") end
	uci:delete('wireless', sname)
	reloadBit(dirtyList, 'network'); commitBit(dirtyList, 'wireless')
end


--[[ Switch between wireless static IP and DHCP ]]
function reconf.staticaddr_add(dirtyList)
	uci:set('network', wifi.NET, 'interface')
	--TODO: remove ifname on wlan interface?
	--NOTE: 'type = "bridge"' should -not- be added as this prevents defining a separate dhcp pool (http://wiki.openwrt.org/doc/recipes/routedap)
	M.uciTableSet('network', wifi.NET, {
		proto = 'static',
		ipaddr = settings.get('network.ap.address'),
		netmask = settings.get('network.ap.netmask')
	})
	bothBits(dirtyList, 'network')
end
--TODO: replace repeated deletes by M.uciTableDelete
function reconf.staticaddr_rm(dirtyList)
	uci:set('network', wifi.NET, 'interface')
	uci:set('network', wifi.NET, 'proto', 'dhcp')
	uci:delete('network', wifi.NET, 'ipaddr')
	uci:delete('network', wifi.NET, 'netmask')
	--uci:delete('network', wifi.NET, 'type') --do not remove since it is not added anymore
	bothBits(dirtyList, 'network')
end


--[[ Add/remove DHCP pool for wireless net ]]
function reconf.dhcppool_add_noreload(dirtyList) reconf.dhcppool_add(dirtyList, true) end
function reconf.dhcppool_add(dirtyList, noReload)
	uci:set('dhcp', wifi.NET, 'dhcp') --create section
	M.uciTableSet('dhcp', wifi.NET, {
		interface = wifi.NET,
		start = '100',
		limit = '150',
		leasetime = '12h',
	})
	commitBit(dirtyList, 'dhcp');
	if noReload == nil or noReload == false then reloadBit(dirtyList, 'dnsmasq') end
end
function reconf.dhcppool_rm(dirtyList)
	uci:delete('dhcp', wifi.NET)
	commitBit(dirtyList, 'dhcp'); reloadBit(dirtyList, 'dnsmasq')
end


--[[ Add/remove webserver 404 redirection and denial of dirlisting ]]
function reconf.wwwredir_add(dirtyList)
	uci:set('uhttpd', 'main', 'error_page', '/www/index.html')
	uci:set('uhttpd', 'main', 'no_dirlist', '1')
	bothBits(dirtyList, 'uhttpd')
end
function reconf.wwwredir_rm(dirtyList)
	uci:delete('uhttpd', 'main', 'error_page')
	uci:delete('uhttpd', 'main', 'no_dirlist')
	bothBits(dirtyList, 'uhttpd')
end


--[[ Add/remove redirecton of all DNS requests to self ]]
function reconf.dnsredir_add(dirtyList)
	local redirText = '/#/' .. settings.get('network.ap.address')
	local sname = utils.getUciSectionName('dhcp', 'dnsmasq')
	if sname == nil then return log:error("dhcp config does not contain a dnsmasq section") end
	if uci:get('dhcp', sname, 'address') ~= nil then return log:debug("DNS address redirection already in place, not re-adding", false) end
	
	uci:set('dhcp', sname, 'address', {redirText})
	commitBit(dirtyList, 'dhcp'); reloadBit(dirtyList, 'dnsmasq')
end
function reconf.dnsredir_rm(dirtyList)
	local sname = utils.getUciSectionName('dhcp', 'dnsmasq')
	if sname == nil then return log:error("dhcp config does not contain a dnsmasq section") end
	
	uci:delete('dhcp', sname, 'address')
	commitBit(dirtyList, 'dhcp'); reloadBit(dirtyList, 'dnsmasq')
end


--TODO: handle os.rename() return values (nil+msg on error)
function reconf.wwwcaptive_add(dirtyList)
	if utils.exists(M.WWW_CAPTIVE_INDICATOR) then
		return log:debug("WWW captive directory already in place, not redoing", false)
	end
	local rv,reason = os.rename('/www', M.WWW_RENAME_NAME)
	if rv == true then
		utils.symlink(M.WWW_CAPTIVE_PATH, '/www')
		return true
	else
		return log:error("Could not rename /www to " .. M.WWW_RENAME_NAME .. "(" .. reason .. ")")
	end
end
function reconf.wwwcaptive_rm(dirtyList)
	if not utils.exists(M.WWW_CAPTIVE_INDICATOR) then return log:debug("WWW captive directory not in place, not undoing", false) end
	os.remove('/www')
	if os.rename(M.WWW_RENAME_NAME, '/www') ~= true then
		return log:error("Could not rename " .. M.WWW_RENAME_NAME .. " to /www")
	end
	return true
end


--[[ Setup/remove NAT reflection to redirect all IPs ]]
function reconf.natreflect_add(dirtyList)
	uci:set('firewall', 'portalreflect', 'redirect');
	M.uciTableSet('firewall', 'portalreflect', {
		src = 'lan',
		proto = 'tcp',
		src_dport = '80',
		dest_port = '80',
		dest_ip = settings.get('network.ap.address'),
		target = 'DNAT'
	})
	bothBits(dirtyList, 'firewall')
end
function reconf.natreflect_rm(dirtyList)
	uci:delete('firewall', 'portalreflect')
	bothBits(dirtyList, 'firewall')
end

--- Sets up access point mode.
-- Note: this function might belong in the wlanconfig module but that would introduce
-- a circular dependency, easiest solution is to place the function here.
-- @tparam string ssid The SSID to use for the access point.
-- @return True on success or nil+msg on error.
function M.setupAccessPoint(ssid)
	M.switchConfiguration{apnet="add_noreload"}
	wifi.activateConfig(ssid)
	-- NOTE: dnsmasq must be reloaded after network or it will be unable to serve IP addresses
	M.switchConfiguration{ wifiiface="add", network="reload", staticaddr="add", dhcppool="add_noreload", wwwredir="add", dnsredir="add" }
	M.switchConfiguration{dhcp="reload"}
	
	return true
end

--- Associates wlan device as client with the given SSID.
-- Note: this function might belong in the wlanconfig module but that would introduce
-- a circular dependency, easiest solution is to place the function here.
-- @tparam string ssid The SSID to associate with.
-- @tparam string passphrase The passphrase (if any) to use, may be left out if a UCI configuration exists.
-- @tparam boolean recreate If true, a new UCI configuration based on scan data will always be created, otherwise an attempt will be made to use an existing configuration.
-- @return True on success or nil+msg on error.
function M.associateSsid(ssid, passphrase, recreate)
	-- see if previously configured network for given ssid exists
	local cfg = nil
	for _, net in ipairs(wifi.getConfigs()) do
		if net.mode ~= "ap" and net.ssid == ssid then
			cfg = net
			break
		end
	end
	
	-- if not, or if newly created configuration is requested, create a new configuration
	if cfg == nil or recreate ~= nil then
		local scanResult = wifi.getScanInfo(ssid)
		if scanResult ~= nil then
			wifi.createConfigFromScanInfo(scanResult, passphrase)
		else
			--check for error
			return nil,"no wireless network with requested SSID is available"
		end
	end
	
	-- try to associate with the network
	wifi.activateConfig(ssid)
	--M.switchConfiguration{ wifiiface="add", apnet="rm", staticaddr="rm", dhcppool="rm", wwwredir="rm", dnsredir="rm", wwwcaptive="rm", wireless="reload" }
	M.switchConfiguration{ wifiiface="add", apnet="rm", staticaddr="rm", dhcppool="rm", wwwredir="rm", dnsredir="rm", wireless="reload" }
	
	-- check if we are actually associated
	local status = wifi.getDeviceState()
	if not status.ssid or status.ssid ~= ssid then
		return nil,"could not associate with network (incorrect passphrase?)"
	end
	
	return true
end

return M
