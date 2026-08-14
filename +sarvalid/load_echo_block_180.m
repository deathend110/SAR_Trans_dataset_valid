function signal180 = load_echo_block_180(manifest_row, S180, block_width)
%LOAD_ECHO_BLOCK_180 读取未经1:3抽取的180 MHz连续复回波块。

persistent cached_path cached_raw
file_path = string(manifest_row.FilePath(1));
if isempty(cached_path) || cached_path ~= file_path
    loaded = load(file_path);
    names = fieldnames(loaded);
    cached_raw = loaded.(names{1});
    cached_path = file_path;
end
start_idx = manifest_row.CStart(1);
stop_idx = start_idx + block_width - 1;
if size(cached_raw, 1) < S180.nrn || size(cached_raw, 2) < stop_idx
    error('sarvalid:Echo180BlockOutOfRange', '180 MHz轨迹块尺寸不足。');
end
signal180 = cached_raw(1:S180.nrn, start_idx:stop_idx);
end
