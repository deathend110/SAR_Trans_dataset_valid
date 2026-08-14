function key = stable_file_key(method, q_total, alpha)
%STABLE_FILE_KEY 构造不依赖区域设置的ASCII文件键。

method_key = lower(regexprep(char(string(method)), '[^A-Za-z0-9]+', '_'));
key = string(method_key) + "_q" + encode_number(q_total);
if startsWith(string(method), "BARU_")
    key = key + "_a" + encode_number(alpha);
end
end

function value = encode_number(number)
text_value = sprintf('%.12g', number);
text_value = strrep(text_value, '-', 'm');
text_value = strrep(text_value, '.', 'p');
text_value = strrep(text_value, '+', '');
value = string(text_value);
end
