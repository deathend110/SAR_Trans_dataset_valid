function [input_sequence, gt_sequence, input_ranges] = ...
        normalize_hlh_with_policy(mixed_roi, gt_roi, h_ratio, ...
        gt_stats, h_stats, l_stats, joint_stats, policy, patch_size)
%NORMALIZE_HLH_WITH_POLICY 用显式策略归一化一条H-L-H序列。

arguments
    mixed_roi
    gt_roi
    h_ratio
    gt_stats (1, 1) struct
    h_stats (1, 1) struct
    l_stats (1, 1) struct
    joint_stats (1, 1) struct
    policy (1, 1) string
    patch_size (1, 1) double {mustBePositive, mustBeInteger}
end

frame_count = size(mixed_roi, 3);
if ~isequal(size(mixed_roi), size(gt_roi)) || numel(h_ratio) ~= frame_count
    error('sarvalid:HLHNormalizationSizeMismatch', ...
        '输入、GT和H比例必须描述同一条序列。');
end
if patch_size > size(mixed_roi, 1) || patch_size > size(mixed_roi, 2)
    error('sarvalid:HLHNormalizationCropSize', ...
        '指标裁剪尺寸不能超过归一化ROI尺寸。');
end
if ~ismember(policy, ["legacy_split", "joint_hl_shared"])
    error('sarvalid:UnknownHLHNormalizationPolicy', ...
        '未知H/L归一化策略：%s。', policy);
end

validate_stats(gt_stats, "GT");
validate_stats(h_stats, "H");
validate_stats(l_stats, "L");
validate_stats(joint_stats, "JointHL");

input_sequence = zeros(patch_size, patch_size, frame_count, 'single');
gt_sequence = zeros(size(input_sequence), 'single');
VMin = zeros(frame_count, 1);
VMax = zeros(frame_count, 1);
for frame_idx = 1:frame_count
    gt_normalized = normalize_roi( ...
        gt_roi(:, :, frame_idx), gt_stats.VMin, gt_stats.VMax);
    if policy == "joint_hl_shared"
        active_stats = joint_stats;
    elseif h_ratio(frame_idx) == 1
        active_stats = h_stats;
    else
        active_stats = l_stats;
    end
    input_normalized = normalize_roi( ...
        mixed_roi(:, :, frame_idx), active_stats.VMin, active_stats.VMax);
    input_sequence(:, :, frame_idx) = single( ...
        sarvalid.crop_center(input_normalized, patch_size));
    gt_sequence(:, :, frame_idx) = single( ...
        sarvalid.crop_center(gt_normalized, patch_size));
    VMin(frame_idx) = active_stats.VMin;
    VMax(frame_idx) = active_stats.VMax;
end
FrameIdx = (0:frame_count-1).';
input_ranges = table(FrameIdx, VMin, VMax);
end

function output = normalize_roi(image, v_min, v_max)
output = (double(abs(image)) - v_min) / (v_max - v_min);
output = single(max(0, min(1, output)));
end

function validate_stats(stats, label)
if ~isfinite(stats.VMin) || ~isfinite(stats.VMax) || ...
        stats.VMax <= stats.VMin
    error('sarvalid:InvalidHLHNormalizationStats', ...
        '%s归一化统计必须有限且VMax大于VMin。', label);
end
end
