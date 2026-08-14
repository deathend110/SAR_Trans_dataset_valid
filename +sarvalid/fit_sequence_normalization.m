function [norm_stats, audit] = fit_sequence_normalization(sequence_cells, manifest, cfg)
%FIT_SEQUENCE_NORMALIZATION 用calibration序列拟合GT/MIXED全局归一化。

if numel(sequence_cells) ~= height(manifest)
    error('sarvalid:SequenceNormalizationCount', '序列数量与清单行数不一致。');
end
row_count = height(manifest) * 2;
Scene = strings(row_count, 1);
Modality = strings(row_count, 1);
Split = repmat("calibration", row_count, 1);
Pixels = cell(row_count, 1);
for idx = 1:height(manifest)
    sequence = sequence_cells{idx};
    rows = (idx-1)*2 + (1:2);
    Scene(rows) = manifest.Scene(idx);
    Modality(rows) = ["GT"; "MIXED"];
    Pixels(rows) = {sequence.gt_raw; sequence.input_raw};
end
samples = table(Scene, Modality, Split, Pixels);
[norm_stats, audit] = sarvalid.fit_global_normalization( ...
    samples, "calibration", ...
    LowPercentile=cfg.normalization.low_percentile, ...
    HighPercentile=cfg.normalization.high_percentile);
end
