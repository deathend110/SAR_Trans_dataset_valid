function cache = load_stage_a_cache(manifest, S60, patch_size)
%LOAD_STAGE_A_CACHE 将小型开发集回波和GT缓存到内存。

arguments
    manifest table
    S60 (1, 1) struct
    patch_size (1, 1) double {mustBePositive, mustBeInteger} = 512
end

num_samples = height(manifest);
empty_item = struct("sample_id", 0, "scene", "", "signal", [], "gt_raw", []);
cache = repmat(empty_item, num_samples, 1);
for sample_idx = 1:num_samples
    signal = sarvalid.load_echo_block(manifest(sample_idx, :), S60, S60.nan);
    gt = sarvalid.generate_gt_image(signal, S60, patch_size);
    cache(sample_idx) = struct( ...
        "sample_id", manifest.SampleID(sample_idx), ...
        "scene", string(manifest.Scene(sample_idx)), ...
        "signal", signal, "gt_raw", single(gt));
end
end
