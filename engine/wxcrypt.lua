-- engine/wxcrypt.lua — the envelope WeCom wraps a callback in.
--
-- Exports: wxcrypt_config, wxcrypt_signature, wxcrypt_open
--
-- WHY THIS IS HERE AT ALL. The app channel (engine/notify.lua) is refused from
-- an address the company has not declared trusted — "errcode 60020: not allow
-- to access from your ip", which is what a host outside mainland China gets —
-- and the console will not open that field until the application has a
-- callback URL that answers its verification. So this exists to unlock a text
-- field, not to receive anything: what arrives afterwards is read and dropped.
--
-- The scheme is Tencent's WXBizMsgCrypt, the same one 公众号 uses:
--
--   key        = base64(EncodingAESKey .. '=')   -- 43 characters in, 32 bytes
--   iv         = the key's first 16 bytes
--   plain      = unpad(AES-256-CBC-decrypt(key, iv, base64(Encrypt)))
--              = random(16) || length(4, big-endian) || message || receiveid
--   signature  = sha1 of token, timestamp, nonce and Encrypt — sorted as
--                strings, then concatenated
--
-- receiveid is the corp id. It is checked rather than read: with the token and
-- the key, it is what says this message was meant for this company, so a
-- message that decrypts but names someone else is refused.
--
-- Pure and offline, like notify_build: given a conf it is a function of its
-- arguments, which is what lets test/unit.lua run Tencent's own vector.

local xutils = require('xutils')

-- WeCom pads to 32 bytes, not to AES's block size of 16.
local PAD_BLOCK = 32

local function cfg_str(key)
    local v = cfg_get(key, '')
    return v ~= '' and v or nil
end

-- The console shows the key as 43 characters: base64 with its padding cut off.
local function decode_key(encoded)
    if #encoded ~= 43 then
        return nil, 'WECOM_CALLBACK_AES_KEY must be the console\'s 43-character EncodingAESKey'
    end
    local key = xutils.base64_decode(encoded .. '=')
    if not key or #key ~= 32 then return nil, 'WECOM_CALLBACK_AES_KEY did not decode to 32 bytes' end
    return key
end

-- The callback's configuration, or nil — plus a reason when the keys are there
-- but unusable, so a typo is reported instead of silently serving nothing.
function g_exports.wxcrypt_config()
    local token, encoded = cfg_str('WECOM_CALLBACK_TOKEN'), cfg_str('WECOM_CALLBACK_AES_KEY')
    if not token and not encoded then return nil end
    local corp = cfg_str('WECOM_CORP_ID')
    if not (token and encoded and corp) then
        return nil, 'WeCom callback: WECOM_CALLBACK_TOKEN, WECOM_CALLBACK_AES_KEY and ' ..
                    'WECOM_CORP_ID are all required'
    end
    local key, err = decode_key(encoded)
    if not key then return nil, 'WeCom callback: ' .. err end
    return { token = token, key = key, receiveid = corp }
end

function g_exports.wxcrypt_signature(token, timestamp, nonce, encrypted)
    local parts = { tostring(token), tostring(timestamp), tostring(nonce), tostring(encrypted) }
    table.sort(parts)
    return xutils.sha1_hex(table.concat(parts))
end

-- Check one callback request and return the message inside it, or nil plus the
-- reason it was refused. Every refusal is the same to the caller: a request
-- that fails here is answered 403 whichever step it failed at, because the
-- steps differ only in what an attacker would learn from them.
function g_exports.wxcrypt_open(conf, signature, timestamp, nonce, encrypted)
    if type(signature) ~= 'string' or type(timestamp) ~= 'string' or
       type(nonce) ~= 'string' or type(encrypted) ~= 'string' then
        return nil, 'missing parameter'
    end
    if wxcrypt_signature(conf.token, timestamp, nonce, encrypted) ~= signature:lower() then
        return nil, 'signature mismatch'
    end

    local raw = xutils.base64_decode(encrypted)
    if not raw or #raw < 32 or #raw % 16 ~= 0 then return nil, 'ciphertext is not whole blocks' end
    local plain, err = xutils.aes_cbc_decrypt(conf.key, conf.key:sub(1, 16), raw)
    if not plain then return nil, tostring(err) end

    -- PKCS#7: the last byte says how many bytes to drop.
    local pad = plain:byte(#plain)
    if pad < 1 or pad > PAD_BLOCK or pad >= #plain then return nil, 'bad padding' end
    local content = plain:sub(1, #plain - pad)

    -- 16 bytes of the sender's randomness, then the length, then the message.
    if #content < 20 then return nil, 'message too short' end
    local a, b, c, d = content:byte(17, 20)
    local len = ((a * 256 + b) * 256 + c) * 256 + d
    if 20 + len > #content then return nil, 'message length out of range' end

    if content:sub(21 + len) ~= conf.receiveid then
        return nil, 'receiveid is another company'
    end
    return content:sub(21, 20 + len)
end
