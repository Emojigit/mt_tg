local http = minetest.request_http_api and minetest.request_http_api()
if not http then
	error("Please allow mt_tg to access the HTTP API!")
end
local S = minetest.get_translator("mt_tg")
local storage = minetest.get_mod_storage()

-- SETTINGS --
local conf = minetest.settings

local poll_interval = tonumber(conf:get("mt_tg.poll_interval")) or 5
local token         = conf:get("mt_tg.token")
if not token then
	error("Missing mt_tg.token!")
end
local target         = tonumber(conf:get("mt_tg.target")) or error("Missing mt_tg.target!")
local api_server     = conf:get("mt_tg.api_server")
if not api_server or api_server  == "" then
	api_server = "https://api.telegram.org/"
end

local ignored_users  = conf:get("mt_tg.ignored_uesrs") or ""
local ignored_userids = {}
for user in string.gmatch(ignored_users, '([^,]+)') do
	local num = tonumber(user)
	if not num then
		error("In mt_tg.ignored_uesrs, " .. user .. " is not a valid integer!")
	end
	ignored_userids[num] = true
end
local send_tg_join  = conf:get_bool("mt_tg.send_tg_join",true)
local send_tg_leave = conf:get_bool("mt_tg.send_tg_leave",true)
local send_tg_cmds  = conf:get_bool("mt_tg.send_tg_cmds",false)
local allow_tg_status = conf:get_bool("mt_tg.allow_tg_status",true)

-- SETTINGS END --

local function send_tg(msg)
	local escaped_msg = tostring(msg)
	escaped_msg = minetest.get_translated_string("en",escaped_msg) or msg
	escaped_msg = minetest.strip_colors(escaped_msg)
	http.fetch({
		url = api_server .. "bot" .. token .. "/sendMessage",
		method = "POST",
		data = {
			chat_id = target,
			text = escaped_msg,
		},
		user_agent = "Minetest-Telegram-Relay",
		multipart = true,
	},function(resp)
		if not resp.succeeded then
			minetest.log("error","sendMessage Failed, Responce data: " .. resp.data)
		end
	end)
end
local orig_send_all = minetest.chat_send_all
function minetest.chat_send_all(msg)
	send_tg(msg)
	orig_send_all(msg)
end

local function parse_message(msg)
	storage:set_int("tg_offset", msg.update_id)
	if msg.message then -- Normal messages
		local message = msg.message
		if message.chat.id ~= target then return end
		-- IGNORE USERS --
		if (message.sender_chat and ignored_userids[message.sender_chat.id]) or ignored_userids[message.from.id] then
			return
		end
		-- DISPLAY NAME --
		local disp_name
		if message.sender_chat then -- Send on behalf of a chat
			disp_name = message.sender_chat.title or ("Chn-" .. tostring(message.sender_chat.id))
		else -- Send by the individual directly
			disp_name = message.from.first_name .. (message.from.last_name or "") .. (message.from.is_premium and " *" or "")
		end
		-- DISPLAY NAME END --
		-- APPEND STR --
		local append_str = ""
		if message.reply_to_message then
			local rep_disp_name
			if message.reply_to_message.sender_chat then -- Send on behalf of a chat
				rep_disp_name = message.reply_to_message.sender_chat.title
					or ("Chn-" .. tostring(message.reply_to_message.sender_chat.id))
			else -- Send by the individual directly
				rep_disp_name = message.reply_to_message.from.first_name .. (message.reply_to_message.from.last_name or "")
			end
			local msg_short = string.sub(message.reply_to_message.text or message.reply_to_message.caption or "",1,20)
			append_str = S("Re @1 \"@2\"",rep_disp_name,msg_short) .. ": "
		else
			local fwd_name
			if message.forward_sender_name then -- Private Fwd
				fwd_name = message.forward_sender_name
			elseif message.forward_from_chat then -- Forwarded from a channel
				fwd_name = message.forward_from_chat.title or ("Chn-" .. tostring(message.forward_from_chat.id))
			elseif message.forward_from then
				fwd_name = message.forward_from.first_name .. (message.forward_from.last_name or "")
					.. (message.forward_from.is_premium and " *" or "")
			end
			if fwd_name then
				append_str = S("FWD @1",fwd_name) .. ": "
			end
		end
		-- APPEND STR END --
		-- MESSAGE DETECT --
		if message.new_chat_members then
			if send_tg_join then
				for _,y in ipairs(message.new_chat_members) do
					local user_name = y.first_name .. (y.last_name or "")
					orig_send_all("<" .. S("@1 joined Telegram Group.",user_name) .. ">")
				end
			end
			return
		elseif message.left_chat_member then
			if send_tg_leave then
				local user_name = message.left_chat_member.first_name .. (message.left_chat_member.last_name or "")
				orig_send_all("<" .. S("@1 left Telegram Group.",user_name) .. ">")
			end
			return
		else
			-- MESSAGE TYPE DETECT --
			local text
			if message.text then -- Plain Text
				if string.sub(message.text,1,7) == "/status" and allow_tg_status then
					send_tg(minetest.get_server_status())
				end
				if string.sub(message.text,1,1) == "/" and not send_tg_cmds then
					return
				end
				text = message.text
			else
				if message.animation then -- Animations
					text = "<" .. S("Animation: @1x@2, @3 seconds",
						message.animation.width,message.animation.height,message.animation.duration) .. ">"
				elseif message.audio then -- Audio file
					if message.audio.title then
						local performer = message.audio.performer or S("Unknown Performer")
						text = "<" .. S("Audio: @1 by @2, @3 seconds",message.audio.title,performer,message.audio.duration) .. ">"
					else
						text = "<" .. S("Audio: @1 seconds",message.audio.duration) .. ">"
					end
				elseif message.document then -- Do《cuments
					if message.document.file_name then
						text = "<" .. S("Document: @1",message.document.file_name) .. ">"
					else
						text = "<" .. S("Document") .. ">"
					end
				elseif message.photo then -- Photo
					text = "<" .. S("Photo: @1x@2",message.photo[#message.photo].width,message.photo[#message.photo].height) .. ">"
				elseif message.sticker then -- Sticker
					-- text = "<" .. S("Sticker: @1",message.sticker.emoji) .. ">"
					text = "<" .. S("Sticker") .. ">" -- MT does not support showing emojies!
				elseif message.video then -- Video
					text = "<" .. S("Video: @1x@2, @3 seconds",message.video.width,message.video.height,message.video.duration) .. ">"
				elseif message.videonote then
					text = "<" .. S("Video Message: @1 seconds",message.videonote.duration) .. ">"
				elseif message.voice then
					text = "<" .. S("Voice Message: @1 seconds",message.voice.duration) .. ">"
				end
				if text then
					if message.caption then
						text = text .. " " .. message.caption
					end
				else
					if message.contact then
						local contact_name = message.contact.first_name .. (message.contact.last_name or "")
						text = "<" .. S("Contact: @1, @2",contact_name,message.contact.phone_number) .. ">"
					elseif message.dice then
						text = "<" .. S("Dice @1: @2",message.dice.emoji,message.dice.value) .. ">"
					elseif message.game then
						text = "<" .. S("Game \"@1\": @2",message.game.title,message.game.description) .. ">"
					end
				end
			end
			-- MESSAGE DETECT END --
			if text then
				orig_send_all(minetest.format_chat_message(disp_name .. "@TG", append_str .. text))
			else
				minetest.log("warning", "[mt_tg] Received non-text message: " .. dump(message))
			end
			return
		end
	end
end

local function compareMSGS(a,b)
  return a.update_id < b.update_id
end

local function mainloop(first)
	local offset = (storage:get_int("tg_offset") + 1)
	minetest.log("action","getUpdate start, offset " .. tostring(offset))
	http.fetch({
		url = api_server .. "bot" .. token .. "/getUpdates",
		method = "POST",
		data = {
			timeout = poll_interval,
			allowed_updates = "message",
			offset = tostring(offset)
		},
		user_agent = "Minetest-Telegram-Relay",
	},function(resp)
		if not resp.succeeded then
			minetest.log("error","getUpdate Failed, Responce data: " .. resp.data)
		else
			local data = minetest.parse_json(resp.data)
			if not data then
				minetest.log("error","getUpdate Failed, Responce data: " .. resp.data)
			else
				table.sort(data.result,compareMSGS)
				if not first then
					for _,y in ipairs(data.result) do
						minetest.log("action","Processing message " .. tostring(y.update_id))
						parse_message(y)
					end
				else
					if data.result[#data.result] then
						storage:set_int("tg_offset",data.result[#data.result].update_id)
					end
					minetest.chat_send_all("*** " .. S("Relay set. Messages will be relayed to Telegram group."))
				end
			end
		end
		minetest.after(first and 1 or poll_interval,mainloop)
	end)
end

minetest.register_on_mods_loaded(function()
	minetest.register_on_chat_message(function(name,message)
		send_tg(minetest.format_chat_message(name, message))
	end)
	send_tg("*** Server started!")
	minetest.after(0,mainloop,true)
end)

minetest.register_on_shutdown(function()
	send_tg("*** Server shutting down...")
end)
