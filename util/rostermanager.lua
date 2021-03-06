-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2008-2013, Kim Alvefur, Matthew Wild, Marco Cirillo, Waqas Hussain

local log = require "util.logger".init("rostermanager");

local setmetatable = setmetatable;
local format = string.format;
local pcall = pcall;
local pairs, ipairs = pairs, ipairs;
local tostring = tostring;

local hosts = hosts;
local bare_sessions = bare_sessions;

local datamanager = require "util.datamanager";
local um_user_exists = require "core.usermanager".user_exists;
local st = require "util.stanza";
local jid_split = require "util.jid".split;

local _ENV = nil;

local save_roster, add_to_roster, remove_from_roster, roster_push, load_roster, get_readonly_rosters, get_readonly_item,
	process_inbound_subscription_approval, process_inbound_subscription_cancellation, process_inbound_unsubscribe,
	is_contact_subscribed, is_contact_pending_in, set_contact_pending_in, is_contact_pending_out,
	set_contact_pending_out, unsubscribe, subscribed, unsubscribed, process_outbound_subscription_request;

function add_to_roster(session, jid, item)
	if session.roster then
		local old_item = session.roster[jid];
		session.roster[jid] = item;
		if save_roster(session.username, session.host) then
			return true;
		else
			session.roster[jid] = old_item;
			return nil, "wait", "internal-server-error", "Unable to save roster";
		end
	else
		return nil, "auth", "not-authorized", "Session's roster not loaded";
	end
end

function remove_from_roster(session, jid)
	if session.roster then
		local old_item = session.roster[jid];
		session.roster[jid] = nil;
		if save_roster(session.username, session.host) then
			return true;
		else
			session.roster[jid] = old_item;
			return nil, "wait", "internal-server-error", "Unable to save roster";
		end
	else
		return nil, "auth", "not-authorized", "Session's roster not loaded";
	end
end

function roster_push(username, host, jid)
	local roster = jid and jid ~= "pending" and hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster;
	if roster then
		local item = hosts[host].sessions[username].roster[jid];
		local stanza = st.iq({type="set"});
		stanza:tag("query", {xmlns = "jabber:iq:roster", ver = tostring(roster[false].version or "1")  });
		if item then
			stanza:tag("item", {jid = jid, subscription = item.subscription, name = item.name, ask = item.ask});
			for group in pairs(item.groups) do
				stanza:tag("group"):text(group):up();
			end
		else
			stanza:tag("item", {jid = jid, subscription = "remove"});
		end
		stanza:up();
		stanza:up();
		-- stanza ready
		for _, session in pairs(hosts[host].sessions[username].sessions) do
			if session.interested then
				-- FIXME do we need to set stanza.attr.to?
				session.send(stanza);
			end
		end
	end
end

function load_roster(username, host)
	local jid = username.."@"..host;
	log("debug", "load_roster: asked for: %s", jid);
	local user = bare_sessions[jid];
	local roster;
	if user then
		roster = user.roster;
		if roster then return roster; end
		log("debug", "load_roster: loading for new user: %s@%s", username, host);
	else
		log("debug", "load_roster: loading for offline user: %s@%s", username, host);
	end
	local data, err = datamanager.load(username, host, "roster");
	roster = data or {};
	if user then user.roster = roster; end
	if not roster[false] then roster[false] = { broken = err or nil }; end
	if roster[jid] then
		roster[jid] = nil;
		log("warn", "roster for %s has a self-contact", jid);
	end
	if not err then
		hosts[host].events.fire_event("roster-load", username, host, roster);
	end
	return roster, err;
end

function save_roster(username, host, roster)
	if not um_user_exists(username, host) then
		log("debug", "not saving roster for %s@%s: the user doesn't exist", username, host);
		return nil;
	end

	log("debug", "save_roster: saving roster for %s@%s", username, host);
	if not roster then
		roster = hosts[host] and hosts[host].sessions[username] and hosts[host].sessions[username].roster;
	end
	if roster then
		local __readonly = roster.__readonly;
		if __readonly then
			roster.__readonly = nil;
		end

		local metadata = roster[false];
		if not metadata then
			metadata = {};
			roster[false] = metadata;
		end
		if metadata.version ~= true then
			metadata.version = (metadata.version or 0) + 1;
		end
		if roster[false].broken then return nil, "Not saving broken roster" end
		local ok, err = datamanager.store(username, host, "roster", roster);
		roster.__readonly = __readonly;
		return ok, err;
	end
	log("warn", "save_roster: user had no roster to save");
	return nil;
end

function get_readonly_rosters(user, host)
	local bare_session = bare_sessions[user .. "@" .. host];
	local roster = (bare_session and bare_session.roster) or load_roster(user, host);
	local readonly = roster.__readonly;
	if not readonly then 
		return function() end
	else
		local i, n = 0, #readonly;
		return function() 
			i = i + 1;
			if i <= n then return readonly[i]; end
		end
	end
end

function get_readonly_item(user, host, jid)
	for ro_roster in get_readonly_rosters(user, host) do
		if ro_roster[jid] then return ro_roster[jid]; end
	end

	return nil;
end

function process_inbound_subscription_approval(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and item.ask then
		if item.subscription == "none" then
			item.subscription = "to";
		else -- subscription == from
			item.subscription = "both";
		end
		item.ask = nil;
		return save_roster(username, host, roster);
	end
end

function process_inbound_subscription_cancellation(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local changed = nil;
	if is_contact_pending_out(username, host, jid) then
		item.ask = nil;
		changed = true;
	end
	if item then
		if item.subscription == "to" then
			item.subscription = "none";
			changed = true;
		elseif item.subscription == "both" then
			item.subscription = "from";
			changed = true;
		end
	end
	if changed then
		return save_roster(username, host, roster);
	end
end

function process_inbound_unsubscribe(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local changed = nil;
	if is_contact_pending_in(username, host, jid) then
		roster.pending[jid] = nil; -- TODO maybe delete roster.pending if empty?
		changed = true;
	end
	if item then
		if item.subscription == "from" then
			item.subscription = "none";
			changed = true;
		elseif item.subscription == "both" then
			item.subscription = "to";
			changed = true;
		end
	end
	if changed then
		return save_roster(username, host, roster);
	end
end

local function _get_online_roster_subscription(jidA, jidB)
	local user = bare_sessions[jidA];
	if not user then return nil; end
	local username, host = jid_split(jidA); 
	local roster = user.roster;

	local readonly_item = get_readonly_item(username, host, jidB);
	if readonly_item then return readonly_item.subscription; end

	local item = roster[jidB] or { subscription = "none" };
	return item and item.subscription;
end
function is_contact_subscribed(username, host, jid)
	do
		local selfjid = username.."@"..host;
		local subscription = _get_online_roster_subscription(selfjid, jid);
		if subscription then return (subscription == "both" or subscription == "from"); end
		local subscription = _get_online_roster_subscription(jid, selfjid);
		if subscription then return (subscription == "both" or subscription == "to"); end
	end
	local roster, err = load_roster(username, host);
	local item = roster[jid];
	if item then
		return (item.subscription == "from" or item.subscription == "both"), err;
	end

	local readonly_item = get_readonly_item(username, host, jid);
	if readonly_item then
		return (readonly_item.subscription == "from" or readonly_item.subscription == "both");
	end
end

function is_contact_pending_in(username, host, jid)
	local roster = load_roster(username, host);
	return roster.pending and roster.pending[jid];
end
function set_contact_pending_in(username, host, jid, pending)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "from" or item.subscription == "both") then
		return;
	end
	if not roster.pending then roster.pending = {}; end
	roster.pending[jid] = true;
	return save_roster(username, host, roster);
end
function is_contact_pending_out(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	return item and item.ask;
end
function set_contact_pending_out(username, host, jid) -- subscribe
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.ask or item.subscription == "to" or item.subscription == "both") then
		return true;
	end
	if not item then
		item = {subscription = "none", groups = {}};
		roster[jid] = item;
	end
	item.ask = "subscribe";
	log("debug", "set_contact_pending_out: saving roster; set %s@%s.roster[%q].ask=subscribe", username, host, jid);
	return save_roster(username, host, roster);
end
function unsubscribe(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if not item then return false; end
	if (item.subscription == "from" or item.subscription == "none") and not item.ask then
		return true;
	end
	item.ask = nil;
	if item.subscription == "both" then
		item.subscription = "from";
	elseif item.subscription == "to" then
		item.subscription = "none";
	end
	return save_roster(username, host, roster);
end
function subscribed(username, host, jid)
	if is_contact_pending_in(username, host, jid) then
		local roster = load_roster(username, host);
		local item = roster[jid];
		if not item then -- FIXME should roster item be auto-created?
			item = {subscription = "none", groups = {}};
			roster[jid] = item;
		end
		if item.subscription == "none" then
			item.subscription = "from";
		else -- subscription == to
			item.subscription = "both";
		end
		roster.pending[jid] = nil;
		-- TODO maybe remove roster.pending if empty
		return save_roster(username, host, roster);
	end -- TODO else implement optional feature pre-approval (ask = subscribed)
end
function unsubscribed(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	local pending = is_contact_pending_in(username, host, jid);
	if pending then
		roster.pending[jid] = nil; -- TODO maybe delete roster.pending if empty?
	end
	local subscribed;
	if item then
		if item.subscription == "from" then
			item.subscription = "none";
			subscribed = true;
		elseif item.subscription == "both" then
			item.subscription = "to";
			subscribed = true;
		end
	end
	local success = (pending or subscribed) and save_roster(username, host, roster);
	return success, pending, subscribed;
end

function process_outbound_subscription_request(username, host, jid)
	local roster = load_roster(username, host);
	local item = roster[jid];
	if item and (item.subscription == "none" or item.subscription == "from") then
		item.ask = "subscribe";
		return save_roster(username, host, roster);
	end
end

return { 
	add_to_roster = add_to_roster, remove_from_roster = remove_from_roster, roster_push = roster_push,
	load_roster = load_roster, save_roster = save_roster, get_readonly_rosters = get_readonly_rosters,
	get_readonly_item = get_readonly_item, process_inbound_subscription_approval = process_inbound_subscription_approval, 
	process_inbound_subscription_cancellation = process_inbound_subscription_cancellation,
	process_inbound_unsubscribe = process_inbound_unsubscribe, is_contact_subscribed = is_contact_subscribed,
	is_contact_pending_in = is_contact_pending_in, set_contact_pending_in = set_contact_pending_in, 
	is_contact_pending_out = is_contact_pending_out, set_contact_pending_out = set_contact_pending_out,
	unsubscribe = unsubscribe, subscribed = subscribed, unsubscribed = unsubscribed,
	process_outbound_subscription_request = process_outbound_subscription_request
};
