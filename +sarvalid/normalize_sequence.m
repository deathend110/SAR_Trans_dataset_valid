function normalized = normalize_sequence(sequence, norm_stats, scene)
%NORMALIZE_SEQUENCE 对GT和mixed九帧统一应用场景级全局统计。

normalized = sequence;
normalized.gt = sarvalid.apply_normalization( ...
    sequence.gt_raw, norm_stats, scene, "GT");
normalized.input = sarvalid.apply_normalization( ...
    sequence.input_raw, norm_stats, scene, "MIXED");
end
