-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.
--
-- As per the sublicensing clause, this file is also MIT/X11 Licensed.
-- ** Copyright (c) 2010-2013, Kim Alvefur, Matthew Wild, Tobias Markmann, Waqas Hussain

local datamanager = require "util.datamanager";
local log = require "util.logger".init("auth_internal_hashed");
local getAuthenticationDatabase = require "util.sasl.scram".getAuthenticationDatabase;
local generate_uuid = require "util.uuid".generate;
local new_sasl = require "util.sasl".new;
local plain_test = module:require "sasl_aux".hashed_plain_test;
local scram_sha1_backend = module:require "sasl_aux".scram_sha1_backend;
local scram_sha256_backend = module:require "sasl_aux".scram_sha256_backend;
local external_backend = module:require "sasl_aux".external_backend;
local to_hex = module:require "sasl_aux".to_hex;
local get_channel_binding_callback = module:require "sasl_aux".get_channel_binding_callback;
local bare_sessions = bare_sessions;

-- Default; can be set per-user
local iteration_count = 4096;

function new_hashpass_provider(host)
	local provider = { name = "internal_hashed" };
	log("debug", "initializing internal_hashed authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		local credentials = datamanager.load(username, host, "accounts") or {};
	
		if credentials.password ~= nil and string.len(credentials.password) ~= 0 then
			if credentials.password ~= password then
				return nil, "Auth failed, provided password is incorrect";
			end

			if provider.set_password(username, credentials.password) == nil then
				return nil, "Auth failed, could not set hashed password from plaintext";
			else
				return true;
			end
		end

		if credentials.iteration_count == nil or credentials.salt == nil or string.len(credentials.salt) == 0 then
			return nil, "Auth failed, stored salt and iteration count information is not complete";
		end
		
		local valid, stored_key, server_key = getAuthenticationDatabase("sha1", password, credentials.salt, credentials.iteration_count);
		
		local stored_key_hex = to_hex(stored_key);
		local server_key_hex = to_hex(server_key);
		
		if valid and stored_key_hex == credentials.stored_key and server_key_hex == credentials.server_key then
			return true;
		else
			return nil, "Auth failed.. invalid username, password, or password hash information";
		end
	end

	function provider.set_password(username, password)
		local account = datamanager.load(username, host, "accounts");
		if account then
			account.salt = account.salt or generate_uuid();
			account.iteration_count = account.iteration_count or iteration_count;
			local valid, stored_key, server_key = getAuthenticationDatabase("sha1", password, account.salt, account.iteration_count);
			local stored_key_hex = to_hex(stored_key);
			local server_key_hex = to_hex(server_key);
			account.stored_key = stored_key_hex;
			account.server_key = server_key_hex;
			valid, stored_key, server_key = getAuthenticationDatabase("sha256", password, account.salt, account.iteration_count);
			stored_key_hex = to_hex(stored_key);
			server_key_hex = to_hex(server_key);
			account.stored_key_256 = stored_key_hex;
			account.server_key_256 = server_key_hex;

			account.password = nil;
			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "Account not available";
	end

	function provider.user_exists(username)
		local account = datamanager.load(username, host, "accounts");
		if not account then
			log("debug", "account not found for username '%s' at host '%s'", username, module.host);
			return nil, "Auth failed, invalid username";
		end
		return true;
	end

	function provider.is_locked(username)
		local account = datamanager.load(username, host, "accounts");
		if not account then
			return nil, "Auth failed, invalid username";
		elseif account and account.locked then
			return true;
		end
		return false;
	end

	function provider.unlock_user(username)
		local account = datamanager.load(username, host, "accounts");
		if not account then
			return nil, "Auth failed, invalid username";
		elseif account and account.locked then
			account.locked = nil;
			local bare_session = bare_sessions[username.."@"..host];
			if bare_session then
				for _, session in pairs(bare_session.sessions) do
					session.locked = nil;
				end
			end
			return datamanager.store(username, host, "accounts", account);
		end
		return nil, "User isn't locked";
	end

	function provider.create_user(username, password, locked)
		if password == nil then
			return datamanager.store(username, host, "accounts", {});
		end
		local salt = generate_uuid();
		local valid, stored_key, server_key = getAuthenticationDatabase("sha1", password, salt, iteration_count);
		local stored_key_hex = to_hex(stored_key);
		local server_key_hex = to_hex(server_key);
		valid, stored_key, server_key = getAuthenticationDatabase("sha256", password, salt, iteration_count);
		local stored_key_hex_256 = to_hex(stored_key);
		local server_key_hex_256 = to_hex(server_key);
		return datamanager.store(username, host, "accounts", 
			{ stored_key = stored_key_hex, server_key = server_key_hex, stored_key_256 = stored_key_hex_256, server_key_256 = server_key_hex_256,
				salt = salt, iteration_count = iteration_count, locked = locked });
	end

	function provider.delete_user(username)
		return datamanager.store(username, host, "accounts", nil);
	end

	function provider.get_sasl_handler(session)
		local testpass_authentication_profile = {
			external = session.secure and external_backend,
			scram_sha_1 = scram_sha1_backend,
			scram_sha_256 = scram_sha256_backend,
			plain_test = plain_test,
			session = session,
			host = host
		};
		if session.secure then
			testpass_authentication_profile.channel_bind_cb = get_channel_binding_callback(session);
			testpass_authentication_profile.order = { "external", "scram_sha_256", "scram_sha_1", "plain_test" };
		else
			testpass_authentication_profile.order = { "scram_sha_256", "scram_sha_1", "plain_test" };
		end
		return new_sasl(host, testpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_hashpass_provider(module.host));
