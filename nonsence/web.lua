--[[
	
	Nonsence Asynchronous event based Lua Web server.
	Author: John Abrahamsen < JhnAbrhmsn@gmail.com >
	
	This module "IOLoop" is a part of the Nonsence Web server.
	< https://github.com/JohnAbrahamsen/nonsence-ng/ >
	
	Nonsence is licensed under the MIT license < http://www.opensource.org/licenses/mit-license.php >:

	"Permission is hereby granted, free of charge, to any person obtaining a copy of
	this software and associated documentation files (the "Software"), to deal in
	the Software without restriction, including without limitation the rights to
	use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
	of the Software, and to permit persons to whom the Software is furnished to do
	so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE."

  ]]

local web = {}
local epoll = assert(require('epoll'), [[Missing required module: Lua Epoll. (https://github.com/Neopallium/lua-epoll)]])
local nixio = assert(require('nixio'), [[Missing required module: Nixio (https://github.com/Neopallium/nixio)]])
local mime = require('nonsence_mime') -- Require MIME module for document types.
local http_status_codes = require('nonsence_codes') -- Require codes module for HTTP status codes.
local json = require('json') -- Require JSON for automagic writing of Lua tables with self:write().

local type = type

------------------------------------------------
---
--
-- Application Class.
--
---
------------------------------------------------
web.Application = {}
function web.Application:new(routinglist)
	application = application or {}
	setmetatable(application, self)
	self.__index = self
	
	self.routinglist = assert(routinglist, 'Please provide a routinglist when using web.Application:new(routinglist)')
	
	---*
	--
	-- Adds the application to the applications table.
	-- Method: listen()
	-- Description: Sets the port to be used for socket.
	--
	---*
	self.listen = function (self, port)
		self.port = assert(port, 'Please provide a port number when using web.Application:listen(port)')
		nonsence_applications[#nonsence_applications + 1] = { port = port, routinglist = routinglist }
	end
	
	return application
end

------------------------------------------------
---
--
-- RequestHandler Class.
--
---
------------------------------------------------
web.RequestHandler = {}
function web.RequestHandler:new(requesthandler)
	requesthandler = requesthandler or {}
	setmetatable(requesthandler, self)
	self.__index = self
	
	self.headers = {}
	self.headers.http_version = "HTTP/1.1"
	self.headers.status_code = 200
	self.headers.server_name = "nonsence version 0.1"
	--self.headers.keep_alive = "Keep-Alive: timeout=3, max=199"
	self.headers.connection  = "Close"
	self.headers.content_type = "text/html"
	self.headers.date = os.date("!%a, %d %b %Y %H:%M:%S GMT")
	self.arguments = {}
	
	local function _write_headers(content_length)
		local headers = self.headers
		local write_to_buffer  = write_to_buffer
		write_to_buffer(headers.http_version .. " ")
		write_to_buffer(headers.status_code .. " " .. http_status_codes[headers.status_code] .. "\r\n")
		write_to_buffer("Server: " .. headers.server_name .. "\r\n")
		write_to_buffer("Connection: " .. headers.connection .. "\r\n")
		write_to_buffer("Content-Type: " .. headers.content_type .. "\r\n")
		write_to_buffer("Content-Length: " .. content_length or 0)
		write_to_buffer("\r\n\r\n")
	end
	
	function self.set_status_code(self, code)
		if code and type(code) == 'number' then
			self.headers.status_code = code
		else
			error('self.status_code() expects type number got: ' .. type(code))
		end
	end
	
	function self._set_arguments(self, args_string)
		local args_string = args_string or ''
		local arguments = {}
		local noDoS = 0;
		for k, v in string.gmatch(args_string, "([^&=]+)=([^&]+)") do
			noDoS = noDoS + 1;
			if (noDoS > 256) then break; end -- hashing DoS attack ;O
			v = v:gsub("+", " "):gsub("%%(%w%w)", function(s) return string.char(tonumber(s,16)) end);
			if (not arguments[k]) then
				arguments[k] = v;
			else
				if ( type(arguments[k]) == "string") then
					local tmp = arguments[k];
					arguments[k] = {tmp};
				end
				table.insert(arguments[k], v);
			end
		end

		--
		-- Set arguments to RequestHandler.
		--
		self.arguments = arguments
	end
	
	function self.get_arguments(self)
		return self.arguments
	end
	
	function self.get_argument(self, key)
		if self.arguments[key] then
			return self.arguments[key]
		else
			-- Die?
		end
	end
	
	function self.write(self, data)
		if data then
			local write_to_buffer  = write_to_buffer
			if type(data) == 'string' or type(data) == 'number' then
				_write_headers(data:len())
				write_to_buffer(data)
			elseif type(data) == 'table' then
				local stringified = json.encode(data)
				self.headers.content_type = 'application/json' -- Set correct JSON type.
				_write_headers(stringified:len())
				write_to_buffer(stringified)
			elseif type(data) == 'function' then
				-- What to do here?
			end
		else
			_write_headers(0)
		end
	end
	
	return requesthandler
end

------------------------------------------------
---
--
-- Tools
--
---
------------------------------------------------

web.parse_headers = function(raw_headers)
	local HTTPHeader = raw_headers
	if HTTPHeader then
		-- Fetch HTTP Method.
		local method, uri = HTTPHeader:match("([%a*%-*]+)%s+(.-)%s")
		-- Fetch all header values by key and value
		local request_header_table = {}	
		for key, value  in HTTPHeader:gmatch("([%a*%-*]+):%s?(.-)[\r?\n]+") do
			request_header_table[key] = value
		end
	return { method = method, uri = uri, extras = request_header_table }
	end
end

return web