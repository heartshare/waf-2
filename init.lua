require "config"
local redis = require "resty.redis"
local cjson = require "cjson"

local match = string.match
local ngxmatch = ngx.re.find
local unescape = ngx.unescape_uri

-- 获取配置项
-- 根据域名自动读取个性化配置
function cfg(name)
	local host = ngx.var.HOST
	
	if conf[host] == nil or conf[host][name] == nil then
		return _G[name]
	end

	return conf[host][name]
end

-- 获取ip地址
function get_client_ip()
	IP  = ngx.var.remote_addr 
	if IP == nil then
		IP  = "unknown"
	end
	return IP
end

-- 日记写入文件
function write(logfile, msg)
    local fd = io.open(logfile, "ab")
    if fd == nil then return end
    fd:write(msg)
    fd:flush()
    fd:close()
end

-- 日记记录
function log(method, url, data, ruletag)
    if cfg("attacklog") then
        local ip = get_client_ip()
        local ua = ngx.var.http_user_agent
        local servername=ngx.var.server_name
        local time = ngx.localtime()
        if ua  then
            line = ip.." ["..time.."] \""..method.." "..servername..url.."\" \""..data.."\"  \""..ua.."\" \""..ruletag.."\"\n"
        else
            line = ip.." ["..time.."] \""..method.." "..servername..url.."\" \""..data.."\" - \""..ruletag.."\"\n"
        end

        local filename = cfg("logPath")..'/'..servername.."_"..ngx.today().."_sec.log"
        write(filename, line)
    end
end

-- 读取规则配置
function read_rule(var)
    file = io.open(rulePath..'/'..var, "r")
    if file == nil then
        return
    end
    t = {}
    for line in file:lines() do
        table.insert(t, line)
    end
    file:close()
    return(t)
end

-- 提示信息输出
function say_html(text)
    if cfg("redirect") then
		text = text or cfg("html")

		-- 判断是否输出json
		if cfg("format") == "json" then
			cjson.encode_empty_table_as_object(false)
			local rerr = {ret = 100503, msg = text, data = {}}
			text = cjson.encode(rerr)
		end

        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.say(text)
        ngx.exit(ngx.status)
    end
end

urlrules = read_rule('url')
argsrules = read_rule('args')
uarules = read_rule('user-agent')
wturlrules = read_rule('whiteurl')
postrules = read_rule('post')
ckrules = read_rule('cookie')

-- 设置redis ip禁用列表
function set_bind_ip(bind_type)
	--连接redis
	local cache = redis.new()
	local ok, err = cache.connect(cache, redisHost, redisPort)
	cache:set_timeout(60000)

	bind_type = bind_type or 100

	-- redis连接失败
	if not ok then
		local ok, err = cache:close()
		ngx.log(ngx.ERR, "redis connect fail: "..redisHost..":"..redisPort)
		return
	end

	-- 获取ip地址
	local ip = get_client_ip()

	local ip_bind_key = "lmb:rate:ipbind:"..ip

	-- IP封禁
	cache:set(ip_bind_key, bind_type)
	cache:expire(ip_bind_key, cfg("ipBindTime"))

	local ok, msg = cache:set_keepalive(60000, 1000) -- 设置连接池

	return 
end

-- 白名单url
function whiteurl()
    if cfg("whiteCheck") then
        if wturlrules ~= nil then
            for _, rule in pairs(wturlrules) do
                if ngxmatch(ngx.var.request_uri, rule, "isjo") then
                    return true 
                 end
            end
        end
    end
    return false
end

-- 文件扩展名拦截
function file_ext_check(ext)
	if not items then
		return false
	end

    local items = set(cfg("blackFileExt"))
    ext = string.lower(ext)
    if ext then
        for rule in pairs(items) do
            if ngx.re.match(ext, rule, "isjo") then
				log("POST", ngx.var.request_uri, "-", "file attack with ext "..ext)
				-- 设置ip临时黑名单
				set_bind_ip(5)
				say_html()
            end
        end
    end
    return false
end

function set(list)
  local set = {}
  for _, l in ipairs(list) do set[l] = true end
  return set
end

-- GET请求参数拦截
function args()
	if not argsrules then
		return false
	end

    for _, rule in pairs(argsrules) do
        local args = ngx.req.get_uri_args()
        for key, val in pairs(args) do
            if type(val) == "table" then
                 local t = {}
                 for k,v in pairs(val) do
                    if v == true then
                        v = ""
                    end
                    table.insert(t, v)
                end
                data = table.concat(t, " ")
            else
                data = val
            end
            if data and type(data) ~= "boolean" and rule ~="" and ngxmatch(unescape(data), rule, "isjo") then
                log("GET", ngx.var.request_uri, "-", rule)
				-- 设置ip临时黑名单
				set_bind_ip(6)
                say_html()
                return true
            end
        end
    end
    return false
end

-- url拦截
function url()
    if cfg("urlDeny") and urlrules ~= nil then
        for _, rule in pairs(urlrules) do
            if rule ~= "" and ngxmatch(ngx.var.request_uri, rule, "isjo") then
                log("GET", ngx.var.request_uri, "-", rule)
				-- 设置ip临时黑名单
				set_bind_ip(7)
                say_html()
                return true
            end
        end
    end
    return false
end

-- user-agent请求头拦截
function ua()
    local ua = ngx.var.http_user_agent

    if ua ~= nil and uarules ~= nil then
        for _, rule in pairs(uarules) do
            if rule ~= "" and ngxmatch(ua, rule, "isjo") then
                log("UA", ngx.var.request_uri, "-", rule)
				-- 设置ip临时黑名单
				set_bind_ip(8)
                say_html()
				return true
            end
        end
    end
    return false
end

-- post请求内容拦截
function body(data)
	if not postrules then 
		return false
	end

    for _,rule in pairs(postrules) do
        if rule ~= "" and data ~= "" and ngxmatch(unescape(data), rule, "isjo") then
            log("POST", ngx.var.request_uri, data, rule)
			-- 设置ip临时黑名单
			set_bind_ip(9)
            say_html()
            return true
        end
    end
    return false
end

-- cookie拦截
function cookie()
    local ck = ngx.var.http_cookie
    if cfg("cookieCheck") and ck and chrules ~= nil then
        for _, rule in pairs(ckrules) do
            if rule ~= "" and ngxmatch(ck, rule, "isjo") then
                log("Cookie", ngx.var.request_uri, "-", rule)
				-- 设置ip临时黑名单
				set_bind_ip(10)
                say_html()
				return true
            end
        end
    end
    return false
end

-- cc攻击拦截
function denycc()
    if cfg("CCDeny") then
        local uri = ngx.var.uri
        local CCcount   = tonumber(string.match(cfg("CCrate"), '(.*)/'))
        local CCseconds = tonumber(string.match(cfg("CCrate"), '/(.*)'))
        local token = get_client_ip()..uri
        local limit = ngx.shared.limit
        local req, _ = limit:get(token)
        if req then
            if req > CCcount then
                log("CCDeny", ngx.var.request_uri, "-", req)
				say_html(cfg("rateHtml"))
                return true
            else
                 limit:incr(token, 1)
            end
        else
            limit:set(token, 1, CCseconds)
        end
    end
    return false
end

function get_boundary()
    local header = ngx.req.get_headers()["content-type"]
    if not header then
        return nil
    end

    if type(header) == "table" then
        header = header[1]
    end

    local m = match(header, ";%s*boundary=\"([^\"]+)\"")
    if m then
        return m
    end

    return match(header, ";%s*boundary=([^\",;]+)")
end

-- ip黑名单
function whiteip()
    if next(cfg("ipWhitelist")) ~= nil and ipWhitelist ~= nil then
        for _, ip in pairs(ipWhitelist) do
            if get_client_ip() == ip then
                return true
            end
        end
    end
	return false
end

-- ip白名单
function blockip()
     if next(cfg("ipBlocklist")) ~= nil and ipBlocklist ~= nil then
         for _, ip in pairs(ipBlocklist) do
             if get_client_ip() == ip then
				 say_html(cfg("blockHtml"))
                 return true
             end
         end
     end
	 return false
end

function check_boundary() 
	local len = string.len
	local sock, err = ngx.req.socket()
	if not sock then
		return
	end

	ngx.req.init_body(128 * 1024)
	sock:settimeout(0)
	local content_length = nil
	content_length = tonumber(ngx.req.get_headers()['content-length'])
	local chunk_size = 4096
	if content_length < chunk_size then
		chunk_size = content_length
	end

	local size = 0
	while size < content_length do
		local data, err, partial = sock:receive(chunk_size)
		data = data or partial
		if not data then
			return
		end
		ngx.req.append_body(data)
		if body(data) then
			return true
		end
		size = size + len(data)
		local m = ngxmatch(data, [[Content-Disposition: form-data;(.+)filename="(.+)\\.(.*)"]], 'ijo')
		if m then
			file_ext_check(m[3])
			filetranslate = true
		else
			if ngxmatch(data, "Content-Disposition:", 'isjo') then
				filetranslate = false
			end
			if filetranslate == false then
				if body(data) then
					return true
				end
			end
		end
		local less = content_length - size
		if less < chunk_size then
			chunk_size = less
		end
	end
	ngx.req.finish_body()
end

-- post请求数据处理
function post()
	local method = ngx.req.get_method()
	if not cfg("postCheck") or method ~= "POST" then   
		return false	
	end

	local boundary = get_boundary()
	if boundary then
		check_boundary()
		return 
	end

	ngx.req.read_body()
	local args = ngx.req.get_post_args()
	if not args then
		return
	end

	for key, val in pairs(args) do
		if type(val) == "table" then
			if type(val[1]) == "boolean" then
				return
			end
			data = table.concat(val, ", ")
		else
			data = val
		end
		if data and type(data) ~= "boolean" and body(data) then
			body(key)
		end
	end
end

-- ip限流
function iplimit()  
	--连接redis
	local cache = redis.new()
	local ok , err = cache.connect(cache, redisHost, redisPort)
	cache:set_timeout(60000)

	--redis连接失败
	if not ok then
		local ok, err = cache:close()
		ngx.log(ngx.ERR, "redis connect fail: "..redisHost..":"..redisPort)
		return true
	end

	-- 获取ip地址
	local ip = get_client_ip()

	-- redis key
	local ip_bind_key        = "lmb:rate:ipbind:"..ip
	local ip_minute_count_key = "lmb:rate:minute:count:"..ip
	local ip_hour_count_key   = "lmb:rate:hour:count:"..os.date("%Y%m%d%H")..":"..ip
	local ip_day_count_key    = "lmb:rate:day:count:"..os.date("%Y%m%d")..":"..ip

	-- ip封禁key
	local is_bind, err = cache:get(ip_bind_key)

	local isok = false

	-- 查询ip是否在封禁时间段内
	if is_bind ~= ngx.null and tonumber(is_bind) > 0 then
		log("IPBIND", ngx.var.request_uri, is_bind, ip)
		isok = true
	else
		local minute_count, err = cache:incr(ip_minute_count_key)
		local hour_count, err = cache:incr(ip_hour_count_key)
		local day_count, err = cache:incr(ip_day_count_key)

		-- 初始化设置过期时间
		if minute_count == 1 then
			cache:expire(ip_minute_count_key, 60)
		end
		if hour_count == 1 then
			cache:expire(ip_hour_count_key, 60 * 60)
		end
		if day_count == 1 then
			cache:expire(ip_day_count_key, 60 * 60 * 24)
		end

		local is_bind = 0
		local bind_time = cfg("ipBindTime")
		-- 每天ip计数
		if day_count >= cfg("ipDayCount") then
			is_bind = 1
			bind_time = cfg("ipDayBindTime")
		-- 小时ip计数
		elseif hour_count >= cfg("ipHourCount") then
			is_bind = 2
			bind_time = cfg("ipHourBindTime")
		-- 分钟ip计数
		elseif minute_count >= cfg("ipMinuteCount") then
			is_bind = 3
			bind_time = cfg("ipMinuteBindTime")
		end

		if is_bind > 0 then
			-- IP封禁
			cache:set(ip_bind_key, is_bind)
			cache:expire(ip_bind_key, bind_time)
		end
	end

	--local ok, err = cache:close()
	local ok, msg = cache:set_keepalive(60000, 1000) -- 设置连接池

	if isok then 
		say_html(cfg("rateHtml"))
	end 

	return isok
end

-- 特殊参数直接返回接口数据
-- 用于提供第三方刷接口请求，避免请求落到PHP层
function special_args_skip()
	local args = ngx.req.get_uri_args()		

	if args["check_flag"] ~= nil 
		and string.find(args["check_flag"], "special") ~= nil then

		local data = {
			["ret"] = 0,
			["msg"] = "",
			["data"] = {}
		}

        ngx.header.content_type = "text/html; charset=utf-8"
        ngx.status = ngx.HTTP_OK
		ngx.say(cjson.encode(data))
		ngx.exit(ngx.status)

		return true
	end

	return false
end

