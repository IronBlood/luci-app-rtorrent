#!/usr/bin/lua

-- Copyright 2014-2015 Sandor Balazsi <sandor.balazsi@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local uci = require "luci.model.uci".cursor()
local date = require "luci.http.protocol.date"
local bencode = require "bencode"
local xml = require "lxp.lom"
local xmlrpc = require "xmlrpc"
local rtorrent = require "rtorrent"
local nixio = require "nixio"
local common = require "luci.model.cbi.rtorrent.common"
require "luci.model.cbi.rtorrent.string"

CONFIG = "rtorrent"

function log(str)
	print(os.date("%Y-%m-%d %H:%M:%S") .. " " .. str)
end

function uci_get_all_sections(config, stype, filter)
	local sections = {}
	uci:foreach(config, stype, function(s)
		if not filter or filter(s) then
			table.insert(sections, s)
		end
	end)
	return sections
end

function get_feeds(filter)
	return uci_get_all_sections(CONFIG, "rss-feed", filter)
end

function get_rules(filter)
	return uci_get_all_sections(CONFIG, "rss-rule", filter)
end

function filter_enabled(s)
	return s.enabled == "1"
end

function next_tag(t, tag, i)
	if not i then i = 1 end
	while t[i] do
		if type(t[i]) == "table" and t[i].tag == tag then
			return t[i], i
		end
		i = i + 1
	end
	return nil, i
end

function contains(tbl, value)
	for _, v in ipairs(tbl) do
		if v == value then
			return true
		end
	end
	return false
end

function get_torrent_size(torrent)
	local sha1_size = 20
	local t, err = bencode.decode(torrent)
	if t then
		local piece_length = tonumber(t["info"]["piece length"])
		local piece_count = t["info"]["pieces"]:len() / sha1_size
		return piece_length * piece_count / 1024 /1024
	else
		return nil
	end
end

--[[ M A I N ]]--

-- TODO: fix character encoding (eg.: lua expat does not support iso8859-2)
-- string.gsub(rss, "[^\128-\193]", "")

local rules = get_rules(filter_enabled)
for _, feed in ipairs(get_feeds(filter_enabled)) do
	log("Downloading \"" .. feed.name .. "\" rss feed")
	local ok, rss = common.get(feed.url)
	local channel = next_tag(xml.parse(rss), "channel")
	local item, i = next_tag(channel, "item")
	local lastupdate = tonumber(feed.lastupdate) or 0
	if item then
		uci:set(CONFIG, feed[".name"], "lastupdate", date.to_unix(next_tag(item, "pubDate")[1]))
		uci:save(CONFIG)
		uci:commit(CONFIG)
	end
	while item do
		local pubdate = date.to_unix(next_tag(item, "pubDate")[1])
		if pubdate > lastupdate then
			local title = next_tag(item, "title")[1]:lower()
			for _, rule in ipairs(rules) do
				if rule.feed and contains(rule.feed:split(";"), feed.name)
				and title:find(rule.match:lower())
				and (not rule.exclude or not title:find(rule.exclude:lower())) then
					local link = next_tag(item, "link")[1]
					local ok, torrent = common.get(link)
					local size = get_torrent_size(torrent)
					if ok and size 
					and (not rule.minsize or (size >= tonumber(rule.minsize)))
					and (not rule.maxsize or (size <= tonumber(rule.maxsize))) then
						log("Matched rss rule: " .. rule.name .. " (" .. link .. ")")
						local params = {}
						table.insert(params, rule.autostart == "1" and "load.raw_start" or "load.raw")
						table.insert(params, "") -- target
						table.insert(params, xmlrpc.newTypedValue((nixio.bin.b64encode(torrent)), "base64"))
						table.insert(params, "d.directory.set=\"" .. rule.destdir .. "\"")
						if rule.tags then table.insert(params, "d.custom2.set=\"" .. rule.tags .. "\"") end
						table.insert(params, "d.custom3.set=" .. nixio.bin.b64encode(link))
						rtorrent.call(unpack(params))
					end
				end
			end
		end
		item, i = next_tag(channel, "item", i + 1)
	end
end

