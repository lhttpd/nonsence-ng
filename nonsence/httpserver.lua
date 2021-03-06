--[[
	
		Nonsence Asynchronous event based Lua Web server.
		Author: John Abrahamsen < JhnAbrhmsn@gmail.com >
		
		This module "httpserver" is a part of the Nonsence Web server.
		
		Contents:
			class HTTPServer, which inherits from TCPServer is a simple
			asynchronous HTTP server implemented in Lua.
			
			class HTTPConnection represent a live HTTP connection to a client.
			
			class HTTPRequest represent a HTTP request, either from a sender
			or a recievers perspective.
		
		For the complete stack hereby called "software package" please see:
		
		https://github.com/JohnAbrahamsen/nonsence-ng/
		
		Many of the modules in the software package are derivatives of the 
		Tornado web server. Tornado is also licensed under Apache 2.0 license.
		For more details on Tornado please see:
		
		http://www.tornadoweb.org/
		
		
		Copyright 2011 John Abrahamsen

		Licensed under the Apache License, Version 2.0 (the "License");
		you may not use this file except in compliance with the License.
		You may obtain a copy of the License at

		http://www.apache.org/licenses/LICENSE-2.0

		Unless required by applicable law or agreed to in writing, software
		distributed under the License is distributed on an "AS IS" BASIS,
		WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
		See the License for the specific language governing permissions and
		limitations under the License.

  ]]
  
--[[

		Load modules

  ]]

local log,nixio,tcpserver,httputil,ioloop,iostream = require('log'), 
require('nixio'), require('tcpserver'), require('httputil'), 
require('ioloop'), require('iostream')

require('middleclass')

--[[

		Localize frequently used functions :>
		
  ]]
  
local class, instanceOf, assert, ostime, type, char, insert, tonumber
, _parse_post_arguments, find = class, instanceOf, assert, os.time, type, 
char, table.insert, tonumber, httputil.parse_post_arguments, string.find

--[[ 

		Declare module table to return on requires.
		
  ]]
  
local httpserver = {}

httpserver.HTTPServer = class('HTTPServer', tcpserver.TCPServer)
--[[ 

		HTTPServer with heritage from TCPServer.
		
		Supported methods are:
		new(request_callback, no_keep_alive, io_loop, xheaders, ssl_options,  kwargs)
			Create a new server object. request_callback parameter is a function to be called on 
			a request.
			
		Example usage of HTTPServer (together with IOLoop):
		
		local httpserver = require('httpserver')
		local ioloop = require('ioloop')
		local ioloop_instance = ioloop.instance()

		-- Request handler function
		function handle_request(request)
			local message = "You requested: " .. request._request.path
			request:write("HTTP/1.1 200 OK\r\nContent-Length:" .. message:len() .."\r\n\r\n")
			request:write(message)
			request:finish()
		end

		http_server = httpserver.HTTPServer:new(handle_request)
		http_server:listen(8888)
		ioloop_instance:start()

  ]]
	  
function httpserver.HTTPServer:init(request_callback, no_keep_alive, io_loop, xheaders,
	ssl_options, kwargs)
	
	self.request_callback = request_callback
	self.no_keep_alive = no_keep_alive or false
	self.xheaders = xheaders or false
	-- Init superclass TCPServer.
	tcpserver.TCPServer:init(io_loop, ssl_options, kwargs)
end

function httpserver.HTTPServer:handle_stream(stream, address)
	-- Redefine handle_stream method from super class TCPServer
	
	httpserver.HTTPConnection:new(stream, address, self.request_callback,
		self.no_keep_alive, self.xheaders)
end

httpserver.HTTPConnection = class('HTTPConnection')
--[[ 

		HTTPConnection class.
		
		Represents a running connection to the server. Basically a helper
		class to HTTPServer.
		
		Supported methods are:
		new(stream, address, request_callback, no_keep_alive, xheaders)
			Create a new server object. request_callback parameter is a function to be called on 
			a request.
			
		write(chunk, callback)
			Writes to the connection and calls callback on complete.
		
		finish()
			Finish the request. Closes the stream.
	
  ]]

function httpserver.HTTPConnection:init(stream, address, request_callback,
	no_keep_alive, xheaders)

	self.stream = stream
	self.address = address
	local function _wrapped_request_callback(RequestObject)
		-- This is needed to retain the context.
		request_callback(RequestObject)
	end
	self.request_callback = _wrapped_request_callback
	self.no_keep_alive = no_keep_alive or false
	self.xheaders = xheaders or false
	self._request = nil
	self._request_finished = false
	self.arguments = {}
	local function _wrapped_header_callback(RequestObject)
		-- This is needed to retain the context.
		self:_on_headers(RequestObject)
	end
	self._header_callback = _wrapped_header_callback
	self.stream:read_until("\r\n\r\n", self._header_callback)
	self._write_callback = nil
end

function httpserver.HTTPConnection:write(chunk, callback)
	-- Writes a chunk of output to the stream.
	-- Callback is done after the chunk is written.
	
	local callback = callback
	assert(self._request, "Request closed")

	if not self.stream:closed() then
		self._write_callback = callback
		local function _on_write_complete_wrap()
			self:_on_write_complete()
		end
		self.stream:write(chunk, _on_write_complete_wrap)
	end
end

function httpserver.HTTPConnection:finish()
	-- Finishes the request
	
	assert(self._request, "Request closed")
	self._request_finished = true
	if not self.stream:writing() then
		self:_finish_request()
	end
end

function httpserver.HTTPConnection:_on_write_complete()
	-- Run callback on complete.

	if self._write_callback then
		local callback = self._write_callback
		self._write_callback = nil
		callback()
	end
	if self._request_finished and not self.stream:writing() then
		self:_finish_request()
	end
end

function httpserver.HTTPConnection:_finish_request()
	-- Finish request.
	
	local disconnect = false
	
	if self.no_keep_alive then
		disconnect = true
	else
		local connection_header = self._request.headers:get("Connection")
		if connection_header then
			connection_header = connection_header:lower()
		end
		if self._request:supports_http_1_1() then
			disconnect = connection_header == "close"
		elseif self._request.headers:get("Content-Length") or
			self._request.headers.method == "HEAD" or
				self._request.method == "GET" then
			disconnect = connection_header ~= "keep-alive"
		else
			disconnect = true
		end
	end
	self._request = nil
	self._request_finished = false
	if disconnect then
		self.stream:close()
		return
	end
	self.stream:read_until("\r\n\r\n", self._header_callback)
end

function httpserver.HTTPConnection:_on_headers(data)
	local headers = httputil.HTTPHeaders:new(data)
	self._request = httpserver.HTTPRequest:new(headers.method, headers.uri, {
		version = headers.version,
		connection = self,
		headers = headers,
		remote_ip = self.address})
	local content_length = headers:get("Content-Length")
	if content_length then
		content_length = tonumber(content_length)
		if content_length > self.stream.max_buffer_size then
			log.error("Content-Length too long")
			self.stream:close()
		end
		if headers:get("Expect") == "100-continue" then 
			self.stream:write("HTTP/1.1 100 (Continue)\r\n\r\n")
		end

		self.stream:read_bytes(content_length, function(data) self:_on_request_body(data) end)
		return
	end
	
	self:request_callback(self._request)
	-- TODO we need error handling here??
end

function httpserver.HTTPConnection:_on_request_body(data)
	self._request.body = data
	local content_type = self._request.headers:get("Content-Type")
	
	if content_type then
		if content_type:find("x-www-form-urlencoded", 1, true) then
			local arguments = _parse_post_arguments(self._request.body)
			if #arguments > 0 then
				self._request.arguments = arguments
			end
		elseif content_type:find("multipart/form-data", 1, true) then
			self.arguments = httputil.parse_multipart_data(self._request.body) or {}
		end
	end
	
	self:request_callback(self._request)
end

httpserver.HTTPRequest = class('HTTPRequest')
--[[ 

		HTTPRequest class.
		
		Represents a HTTP request to the server. 
		
		Supported methods are:
			new(method, uri, {
				version,
				headers,
				body,
				remote_ip,
				protocol,
				host,
				files, 
				connection
			})
				Generate a HTTPRequest object. HTTP headers are parsed
				magically if headers are supplied with kwargs table.
				
			supports_http_1_1()
				Returns true if requester supports HTTP 1.1.
				
			write(chunk, callback.)
				Write chunk to the connection that made the request. Call
				callback when write is done.
				
			finish()
				Finish the request. Close connection.
				
			full_url()
				Return the full URL that the user requested.
				
			request_time()
				Return the time used to handle the request or the 
				time up to now if request not finished.
			
  ]]
  
function httpserver.HTTPRequest:init(method, uri, args)
	
	local headers, body, remote_ip, protocol, host, files, 
	version, connection = nil, nil, nil, nil, nil, nil, "HTTP/1.0",
	nil

	if type(args) == "table" then
		version = args.version or version
		headers = args.headers
		body = args.body
		remote_ip = args.remote_ip
		protocol = args.protocol
		host = args.host
		files = args.files
		connection = args.connection
	end
	
	self.method = method
	self.uri = uri
	self.version = args.version or version
	self.headers = headers or httputil.HTTPHeaders:new()	
	self.body = body or ""

	if connection and connection.xheaders then
		self.remote_ip = self.headers:get("X-Real-Ip") or
			self.headers:get("X-Forwarded-For")
		if not self:_valid_ip(self.remote_ip) then
			self.remote_ip = remote_ip
		end
		self.protocol = self.headers:get("X-Scheme") or
			self.headers:get("X-Forwarded-Proto")
		if self.protocol ~= "http" or self.protocol ~= "https" then
			self.protocol = "http"
		end
	else
		self.remote_ip = remote_ip
		if protocol then
			self.protocol = protocol
		elseif connection and 
			instanceOf(connection.stream, iostream.SSLIOStream) then
			self.protocol = "https"
		else
			self.protocol = "http"
		end
	end
	
	self.host = host or self.headers:get("Host") or "127.0.0.1"
	self.files = files or {}
	self.connection = connection 
	self._start_time = ostime()
	self._finish_time = nil
	self.path = self.headers.url
	self.arguments = self.headers:get_arguments()
end

function httpserver.HTTPRequest:supports_http_1_1()
	return self.version == "HTTP/1.1"
end

function httpserver.HTTPRequest:write(chunk, callback)
	local callback = callback
	assert(type(chunk) == "string")
	self.connection:write(chunk, callback)
end

function httpserver.HTTPRequest:finish()
	self.connection:finish()
	self._finish_time = ostime()
end

function httpserver.HTTPRequest:full_url()
	return self.protocol .. "://" .. self.host .. self.uri
end

function httpserver.HTTPRequest:request_time()
	if not self._finish_time then
		return ostime() - self._start_time
	else
		return self._finish_time - self._start_time
	end
end

function httpserver.HTTPRequest:_valid_ip(ip)
	local ip = ip or ''
	return ip:find("[%d+%.]+") or nil
end

return httpserver
