-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2009-2011, Florian Zeitz, Matthew Wild, Waqas Hussain

local st = require "util.stanza";
local jid_bare, jid_join, jid_section = require "util.jid".bare, require "util.jid".join, require "util.jid".section;
local ipairs, pairs, tonumber, t_insert, t_sort = ipairs, pairs, tonumber, table.insert, table.sort;

local lib = module:require("privacy");

-- Storage functions
local privacy = lib.privacy;
local store_load = lib.store_load;

-- Privacy List functions
local priv_decline_list, priv_activate_list, priv_delete_list, priv_create_list, priv_get_list =
	lib.priv_decline_list, lib.priv_activate_list, lib.priv_delete_list, lib.priv_create_list, lib.priv_get_list;

-- Simple Blocking Command functions
local simple_create_list, simple_delete_list, simple_add_entry, simple_delete_entry,
	simple_process_entries, simple_generate_stanza, simple_push_entries, simple_reorder_list =
	lib.simple_create_list, lib.simple_delete_list, lib.simple_add_entry, lib.simple_delete_entry,
	lib.simple_process_entries, lib.simple_generate_stanza, lib.simple_push_entries, lib.simple_reorder_list;
	
-- Stanza Handlers
local check_incoming, check_outgoing = lib.stanza_check_incoming, lib.stanza_check_outgoing;

local privacy_xmlns = "jabber:iq:privacy";
local blocking_xmlns = "urn:xmpp:blocking";

module:add_feature(privacy_xmlns);
module:add_feature(blocking_xmlns);

module:hook("iq/self/"..privacy_xmlns..":query", function(data)
	local origin, stanza = data.origin, data.stanza;
	
	local query = stanza.tags[1]; -- the query element
	local valid = false;
	local privacy_lists = store_load(origin.username);

	if stanza.attr.type == "set" then
		if #query.tags == 1 then --  the <query/> element MUST NOT include more than one child element
			for _,tag in ipairs(query.tags) do
				if tag.name == "active" or tag.name == "default" then
					if tag.attr.name == nil then -- Client declines the use of active / default list
						valid = priv_decline_list(privacy_lists, origin, stanza, tag.name);
					else -- Client requests change of active / default list
						valid = priv_activate_list(privacy_lists, origin, stanza, tag.name, tag.attr.name);
					end
				elseif tag.name == "list" and tag.attr.name then -- Client adds / edits a privacy list
					if #tag.tags == 0 then -- Client removes a privacy list
						valid = priv_delete_list(privacy_lists, origin, stanza, tag.attr.name);
					else -- Client edits a privacy list
						valid = priv_create_list(privacy_lists, origin, stanza, tag.attr.name, tag.tags);
					end
				end
			end
		end
	elseif stanza.attr.type == "get" then
		local name = nil;
		local _to_retrieve = 0;
		if #query.tags >= 1 then
			for _, tag in ipairs(query.tags) do
				if tag.name == "list" then -- Client requests a privacy list from server
					name = tag.attr.name;
					_to_retrieve = _to_retrieve + 1;
				end
			end
		end
		if _to_retrieve == 0 or _to_retrieve == 1 then
			valid = priv_get_list(privacy_lists, origin, stanza, name);
		end
	end

	if valid ~= true then
		valid = valid or { "cancel", "bad-request", "Couldn't understand request" };
		if valid[1] == nil then
			valid[1] = "cancel";
		end
		if valid[2] == nil then
			valid[2] = "bad-request";
		end
		origin.send(st.error_reply(stanza, valid[1], valid[2], valid[3]));
	else
		privacy:set(origin.username, privacy_lists);
	end

	return true;
end);

module:hook("iq-set/self/"..blocking_xmlns..":block", function(data)
	local origin, stanza = data.origin, data.stanza;
	local privacy_lists = store_load(origin.username);

	local block = stanza.tags[1];
	if #block.tags > 0 then
		simple_create_list(privacy_lists);
		local entries = simple_process_entries(block);
		if not entries then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Item stanza is not well formed"));
			return true;
		end
		
		for i = 1, #entries do simple_add_entry(privacy_lists, entries[i]); end
		simple_push_entries(origin.username, origin.resource, "block", entries);
		
		origin.send(st.reply(stanza));
	else
		origin.send(st.error_reply(stanza, "modify", "bad-request", "You need to specify at least one item to add"));
	end
	
	privacy:set(origin.username, privacy_lists);
	return true;
end);

module:hook("iq-set/self/"..blocking_xmlns..":unblock", function(data)
	local origin, stanza = data.origin, data.stanza;
	local privacy_lists = store_load(origin.username);
	
	if not privacy_lists or not privacy_lists.lists.simple then
		origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Blocking list is empty"));
		return true;
	end
	
	local unblock = stanza.tags[1];
	if #unblock.tags > 0 then -- remove single entries;
		local entries = simple_process_entries(unblock);
		if not entries then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Item stanza is not well formed"));
			return true;
		end
		
		for i = 1, #entries do simple_delete_entry(privacy_lists, entries[i]); end
		if #privacy_lists.lists.simple.items > 0 then --reorder
			simple_reorder_list(privacy_lists);
		else --delete
			simple_delete_list(privacy_lists);
		end
		
		simple_push_entries(origin.username, origin.resource, "unblock", entries);
	else
		simple_delete_list(privacy_list);
		simple_push_entries(origin.username, origin.resource, "unblock");
	end
	
	privacy:set(origin.username, privacy_lists);
	origin.send(st.reply(stanza));
	return true;
end);

module:hook("iq-get/self/"..blocking_xmlns..":blocklist", function(data)
	local origin, stanza = data.origin, data.stanza;
	local privacy_lists = store_load(origin.username);
	local simple = privacy_lists and privacy_lists.lists.simple;
	
	if simple then
		local items = simple.items;
		local entries = {};
		
		for i = 1, #items do t_insert(entries, items[i].jid) end
		local reply = simple_generate_stanza(st.reply(stanza), entries, "blocklist");
		origin.send(reply);
	else
		origin.send(st.reply(stanza):tag("blocklist", { xmlns = blocking_xmlns }));
	end
	
	privacy:set(origin.username, privacy_lists);
	return true;
end);

module:hook("pre-message/full", check_outgoing, 500);
module:hook("pre-message/bare", check_outgoing, 500);
module:hook("pre-message/host", check_outgoing, 500);
module:hook("pre-iq/full", check_outgoing, 500);
module:hook("pre-iq/bare", check_outgoing, 500);
module:hook("pre-iq/host", check_outgoing, 500);
module:hook("pre-presence/full", check_outgoing, 500);
module:hook("pre-presence/bare", check_outgoing, 500);
module:hook("pre-presence/host", check_outgoing, 500);

module:hook("message/full", check_incoming, 500);
module:hook("message/bare", check_incoming, 500);
module:hook("message/host", check_incoming, 500);
module:hook("iq/full", check_incoming, 500);
module:hook("iq/bare", check_incoming, 500);
module:hook("iq/host", check_incoming, 500);
module:hook("presence/full", check_incoming, 500);
module:hook("presence/bare", check_incoming, 500);
module:hook("presence/host", check_incoming, 500);

module.unload = function()
	for jid, session in pairs(bare_sessions) do session.privacy_lists = nil; end
end
