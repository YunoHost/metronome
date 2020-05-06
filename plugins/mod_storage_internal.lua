-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- Additional Contributors: John Regan
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2011-2012, Kim Alvefur, Matthew Wild, Waqas Hussain

local datamanager = require "core.storagemanager".olddm;

local host = module.host;

cache = {};

local driver = { name = "internal" };
local driver_mt = { __index = driver };

function driver:open(store)
	if not cache[store] then cache[store] = setmetatable({ store = store }, driver_mt); end
	return cache[store];
end
function driver:get(user)
	return datamanager.load(user, host, self.store);
end

function driver:set(user, data)
	return datamanager.store(user, host, self.store, data);
end

function driver:stores(user, type, pattern)
	return datamanager.stores(user, host, type, pattern);
end

function driver:store_exists(user, type)
	return datamanager.store_exists(user, host, self.store, type);
end

function driver:purge(user)
	return datamanager.purge(user, host);
end

function driver:nodes(type)
	return datamanager.nodes(host, self.store, type);
end

module:add_item("data-driver", driver);
