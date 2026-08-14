function evaluation = verify_pure_pair(manifest, S60, pair_cfg, ...
        norm_stats, diagnostics_cfg, diagnostic_dir, checkpoint_context)
%VERIFY_PURE_PAIR 用锁定参数和开发集归一化统计评价70个独立样本。

if nargin < 6
    diagnostic_dir = "";
end
if nargin < 7
    checkpoint_context = struct();
end
if strlength(string(diagnostic_dir)) > 0
    sarvalid.ensure_dir(diagnostic_dir);
end

num_samples = height(manifest);
SampleID = manifest.SampleID;
Scene = string(manifest.Scene);
detail = table(SampleID, Scene);
metric_names = ["HPSNR", "HSSIM", "LPSNR", "LSSIM", ...
    "DeltaPSNR", "DeltaSSIM", "HEntropy", "LEntropy", ...
    "HOffSupport", "LOffSupport", ...
    "HRangeLeakage", "LRangeLeakage", ...
    "HAzimuthLeakage", "LAzimuthLeakage"];
for name = metric_names
    detail.(name) = nan(num_samples, 1);
end

initial_state = struct("completed_ids", zeros(0, 1), "detail", table());
checkpoint_enabled = isfield(checkpoint_context, "path") && ...
    isfield(checkpoint_context, "signature");
if checkpoint_enabled
    state = sarvalid.load_checkpoint(string(checkpoint_context.path), ...
        checkpoint_context.signature, initial_state);
else
    state = initial_state;
end
if ~isempty(state.detail)
    for existing_idx = 1:height(state.detail)
        target = find(SampleID == state.detail.SampleID(existing_idx), 1);
        if ~isempty(target)
            detail(target, metric_names) = state.detail(existing_idx, metric_names);
        end
    end
end

seen_scenes = strings(num_samples, 1);
seen_scene_count = 0;
for sample_idx = 1:num_samples
    if ismember(SampleID(sample_idx), state.completed_ids)
        continue;
    end
    signal = sarvalid.load_echo_block(manifest(sample_idx, :), S60, S60.nan);
    [gt_raw, RC_gt] = sarvalid.generate_gt_image(signal, S60, 512);
    sample_pair = pair_cfg;
    sample_pair.H.seed = pair_cfg.H.seed + SampleID(sample_idx) * 1000;
    sample_pair.L.seed = pair_cfg.L.seed + SampleID(sample_idx) * 1000 + 1;
    [RC_H, ~] = sarvalid.generate_base_rc(signal, S60, sample_pair.H);
    [RC_L, ~] = sarvalid.generate_base_rc(signal, S60, sample_pair.L);
    h_raw = sarvalid.focus_base_rc(RC_H, S60, 512);
    l_raw = sarvalid.focus_base_rc(RC_L, S60, 512);
    gt = sarvalid.apply_normalization(gt_raw, norm_stats, Scene(sample_idx), "GT");
    h = sarvalid.apply_normalization(h_raw, norm_stats, Scene(sample_idx), "H");
    l = sarvalid.apply_normalization(l_raw, norm_stats, Scene(sample_idx), "L");

    meta = struct("reference_rc", RC_gt, ...
        "support_threshold_ratio", diagnostics_cfg.support_threshold_ratio);
    [h_metrics, h_diag] = sarvalid.evaluate_case( ...
        struct("image", h, "RC_base", RC_H), gt, meta);
    [l_metrics, l_diag] = sarvalid.evaluate_case( ...
        struct("image", l, "RC_base", RC_L), gt, meta);
    detail.HPSNR(sample_idx) = h_metrics.psnr;
    detail.HSSIM(sample_idx) = h_metrics.ssim;
    detail.LPSNR(sample_idx) = l_metrics.psnr;
    detail.LSSIM(sample_idx) = l_metrics.ssim;
    detail.DeltaPSNR(sample_idx) = h_metrics.psnr - l_metrics.psnr;
    detail.DeltaSSIM(sample_idx) = h_metrics.ssim - l_metrics.ssim;
    detail.HEntropy(sample_idx) = h_metrics.entropy;
    detail.LEntropy(sample_idx) = l_metrics.entropy;
    detail.HOffSupport(sample_idx) = h_diag.off_support_ratio;
    detail.LOffSupport(sample_idx) = l_diag.off_support_ratio;
    detail.HRangeLeakage(sample_idx) = h_diag.range_leakage_ratio;
    detail.LRangeLeakage(sample_idx) = l_diag.range_leakage_ratio;
    detail.HAzimuthLeakage(sample_idx) = h_diag.azimuth_leakage_ratio;
    detail.LAzimuthLeakage(sample_idx) = l_diag.azimuth_leakage_ratio;

    if strlength(string(diagnostic_dir)) > 0 && ...
            ~any(seen_scenes(1:seen_scene_count) == Scene(sample_idx))
        file_name = char(Scene(sample_idx) + "_" + ...
            string(pair_cfg.file_key) + ".png");
        sarvalid.save_pure_contact_sheet( ...
            fullfile(diagnostic_dir, file_name), gt, h, l, ...
            string(pair_cfg.file_key) + " / " + Scene(sample_idx));
        seen_scene_count = seen_scene_count + 1;
        seen_scenes(seen_scene_count) = Scene(sample_idx);
    end

    state.detail = [state.detail; detail(sample_idx, :)];
    state.completed_ids(end+1, 1) = SampleID(sample_idx);
    if checkpoint_enabled
        sarvalid.atomic_save(string(checkpoint_context.path), struct("state", state));
    end
end

if any(~isfinite(detail{:, metric_names}), 'all')
    error('sarvalid:NonfiniteVerificationMetrics', ...
        'Stage A验证指标包含非有限值，拒绝写出不完整结果。');
end
summary = struct();
for name = metric_names
    values = detail.(name);
    summary.(name + "_Mean") = mean(values);
    summary.(name + "_Std") = std(values);
end
summary.SampleCount = num_samples;
evaluation = struct("summary", summary, "detail", detail);
end
