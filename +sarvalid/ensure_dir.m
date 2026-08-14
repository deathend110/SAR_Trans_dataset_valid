function ensure_dir(path_value)
%ENSURE_DIR 确保输出目录存在。

if ~exist(path_value, 'dir')
    [ok, message] = mkdir(path_value);
    if ~ok
        error('sarvalid:CreateDirectory', '无法创建目录%s：%s', path_value, message);
    end
end
end
