function write_json(file_path, value)
%WRITE_JSON 以UTF-8写出易审计的JSON配置。

text_value = jsonencode(value, PrettyPrint=true);
fid = fopen(file_path, 'w', 'n', 'UTF-8');
if fid < 0
    error('sarvalid:OpenJSON', '无法写入JSON：%s', file_path);
end
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', text_value);
end
