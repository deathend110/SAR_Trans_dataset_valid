function digest = sha256_text(value)
%SHA256_TEXT 对UTF-8文本生成稳定SHA-256十六进制摘要。

arguments
    value (1, 1) string
end

engine = java.security.MessageDigest.getInstance('SHA-256');
bytes = unicode2native(char(value), 'UTF-8');
engine.update(bytes);
raw = typecast(engine.digest(), 'uint8');
digest = lower(string(reshape(dec2hex(raw, 2).', 1, [])));
end
