function signal60 = load_echo_block(manifest_row, S60, block_width)
%LOAD_ECHO_BLOCK 读取清单指定的180 MHz轨迹片段并抽取为60 MHz回波。

arguments
    manifest_row table
    S60 (1, 1) struct
    block_width (1, 1) double {mustBePositive, mustBeInteger} = S60.nan
end

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
if size(cached_raw, 2) < stop_idx
    error('sarvalid:EchoBlockOutOfRange', ...
        '轨迹%s无法从%d裁出宽度%d。', file_path, start_idx, block_width);
end
signal60 = cached_raw(1:3:end, start_idx:stop_idx);
if size(signal60, 1) < S60.nrn
    error('sarvalid:EchoRowsTooShort', '60 MHz回波距离维不足。');
end
signal60 = signal60(1:S60.nrn, :);
end
