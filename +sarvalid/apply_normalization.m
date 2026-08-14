function normalized = apply_normalization(image, norm_stats, scene, modality)
%APPLY_NORMALIZATION 应用已锁定的场景/模态全局robust min-max。

mask = string(norm_stats.Scene) == string(scene) & ...
    string(norm_stats.Modality) == string(modality);
if sum(mask) ~= 1
    error('sarvalid:NormalizationLookup', ...
        '场景%s模态%s必须唯一匹配一行归一化参数，实际为%d。', ...
        string(scene), string(modality), sum(mask));
end
row = norm_stats(mask, :);
normalized = (double(abs(image)) - row.VMin) / (row.VMax - row.VMin);
normalized = single(max(0, min(1, normalized)));
end
