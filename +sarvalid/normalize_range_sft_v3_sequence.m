function [input_sequence, gt_sequence] = normalize_range_sft_v3_sequence( ...
        mixed_roi, gt_roi, h_ratio, gt_stats, h_stats, l_stats, patch_size)
%NORMALIZE_RANGE_SFT_V3_SEQUENCE 按V3模态协议归一化并中心裁剪一条序列。

% 纯H帧使用H分位数；纯L帧与全部混合帧使用L分位数。归一化始终先在
% 600像素ROI上完成，再中心裁剪到指标尺寸。

frame_count = size(mixed_roi, 3);
if ~isequal(size(mixed_roi), size(gt_roi)) || numel(h_ratio) ~= frame_count
    error('sarvalid:V3NormalizationSizeMismatch', ...
        '输入、GT和H比例必须描述同一条序列。');
end
if patch_size > size(mixed_roi, 1) || patch_size > size(mixed_roi, 2)
    error('sarvalid:V3NormalizationCropSize', ...
        '指标裁剪尺寸不能超过归一化ROI尺寸。');
end

input_sequence = zeros(patch_size, patch_size, frame_count, 'single');
gt_sequence = zeros(size(input_sequence), 'single');
for frame_idx = 1:frame_count
    gt_normalized = normalize_roi(gt_roi(:, :, frame_idx), ...
        scalar_value(gt_stats, "VMin"), scalar_value(gt_stats, "VMax"));
    if h_ratio(frame_idx) == 1
        active_stats = h_stats;
    else
        active_stats = l_stats;
    end
    input_normalized = normalize_roi(mixed_roi(:, :, frame_idx), ...
        scalar_value(active_stats, "VMin"), ...
        scalar_value(active_stats, "VMax"));
    gt_sequence(:, :, frame_idx) = single( ...
        sarvalid.crop_center(gt_normalized, patch_size));
    input_sequence(:, :, frame_idx) = single( ...
        sarvalid.crop_center(input_normalized, patch_size));
end
end

function output = normalize_roi(image, v_min, v_max)
if ~isfinite(v_min) || ~isfinite(v_max) || v_max <= v_min
    error('sarvalid:V3DegenerateNormalization', ...
        '归一化分位数必须有限且VMax大于VMin。');
end
output = (double(abs(image)) - v_min) / (v_max - v_min);
output = single(max(0, min(1, output)));
end

function value = scalar_value(stats, name)
value = stats.(name);
if ~isscalar(value)
    error('sarvalid:V3NormalizationStatsShape', ...
        '每个模态必须只提供一组归一化统计量。');
end
value = double(value);
end
