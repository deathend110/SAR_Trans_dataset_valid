function [norm_stats, audit] = fit_global_normalization(samples, split_name, options)
%FIT_GLOBAL_NORMALIZATION 按场景和模态拟合训练限定的robust min-max。
%
% samples必须包含Scene、Modality、Split和Pixels四列，Pixels为数值数组元胞列。

arguments
    samples table
    split_name (1, 1) string
    options.LowPercentile (1, 1) double = 0.1
    options.HighPercentile (1, 1) double = 99.9
end

required = ["Scene", "Modality", "Split", "Pixels"];
if ~all(ismember(required, string(samples.Properties.VariableNames)))
    error('sarvalid:NormalizationTableSchema', ...
        'samples必须包含Scene、Modality、Split和Pixels列。');
end
if options.LowPercentile < 0 || options.HighPercentile > 100 || ...
        options.LowPercentile >= options.HighPercentile
    error('sarvalid:InvalidPercentiles', '归一化百分位设置无效。');
end

selected = samples(string(samples.Split) == split_name, :);
if isempty(selected)
    error('sarvalid:EmptyNormalizationSplit', ...
        '归一化split %s没有样本。', split_name);
end

groups = unique(selected(:, ["Scene", "Modality"]), 'rows', 'stable');
num_groups = height(groups);
Scene = string(groups.Scene);
Modality = string(groups.Modality);
VMin = zeros(num_groups, 1);
VMax = zeros(num_groups, 1);
SampleCount = zeros(num_groups, 1);
PixelCount = zeros(num_groups, 1);

for group_idx = 1:num_groups
    mask = string(selected.Scene) == Scene(group_idx) & ...
        string(selected.Modality) == Modality(group_idx);
    values = selected.Pixels(mask);
    flattened = cellfun(@(x) double(abs(x(:))), values, ...
        'UniformOutput', false);
    pooled = vertcat(flattened{:});
    pooled = pooled(isfinite(pooled));
    if isempty(pooled)
        error('sarvalid:NoFiniteNormalizationPixels', ...
            '场景%s模态%s没有有限像素。', Scene(group_idx), Modality(group_idx));
    end
    VMin(group_idx) = prctile(pooled, options.LowPercentile);
    VMax(group_idx) = prctile(pooled, options.HighPercentile);
    if VMax(group_idx) <= VMin(group_idx)
        error('sarvalid:DegenerateNormalizationRange', ...
            '场景%s模态%s的归一化范围退化。', Scene(group_idx), Modality(group_idx));
    end
    SampleCount(group_idx) = numel(values);
    PixelCount(group_idx) = numel(pooled);
end

LowPercentile = repmat(options.LowPercentile, num_groups, 1);
HighPercentile = repmat(options.HighPercentile, num_groups, 1);
FitSplit = repmat(split_name, num_groups, 1);
norm_stats = table(Scene, Modality, VMin, VMax, SampleCount, ...
    PixelCount, LowPercentile, HighPercentile, FitSplit);

audit = struct("fit_split", split_name, "input_rows", height(samples), ...
    "selected_rows", height(selected), "group_count", num_groups);
end
