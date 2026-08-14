function atomic_save(file_path, payload)
%ATOMIC_SAVE 先写临时MAT文件，再原子替换正式checkpoint。

arguments
    file_path (1, 1) string
    payload (1, 1) struct
end
output_dir = fileparts(file_path);
if strlength(output_dir) > 0 && ~exist(output_dir, 'dir')
    [ok, message] = mkdir(output_dir);
    if ~ok
        error('sarvalid:CreateDirectory', '无法创建目录%s：%s', output_dir, message);
    end
end
temporary_path = file_path + ".tmp";
save(temporary_path, '-struct', 'payload', '-v7.3');
[ok, message] = movefile(temporary_path, file_path, 'f');
if ~ok
    error('sarvalid:AtomicMove', '无法更新%s：%s', file_path, message);
end
end
