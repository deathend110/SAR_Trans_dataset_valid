function evaluation = verify_pure_pair(manifest, S60, pair_cfg, norm_stats, diagnostics_cfg)
%VERIFY_PURE_PAIR 用锁定参数和开发集归一化统计评价70个独立样本。

num_samples = height(manifest);
SampleID = manifest.SampleID;
Scene = string(manifest.Scene);
HPSNR = zeros(num_samples, 1);
HSSIM = zeros(num_samples, 1);
LPSNR = zeros(num_samples, 1);
LSSIM = zeros(num_samples, 1);
HOffSupport = zeros(num_samples, 1);
LOffSupport = zeros(num_samples, 1);
HRangeLeakage = zeros(num_samples, 1);
LRangeLeakage = zeros(num_samples, 1);
HAzimuthLeakage = zeros(num_samples, 1);
LAzimuthLeakage = zeros(num_samples, 1);
HEntropy = zeros(num_samples, 1);
LEntropy = zeros(num_samples, 1);

for sample_idx = 1:num_samples
    signal = sarvalid.load_echo_block(manifest(sample_idx, :), S60, S60.nan);
    [gt_raw, RC_gt] = sarvalid.generate_gt_image(signal, S60, 512);
    [RC_H, ~] = sarvalid.generate_base_rc(signal, S60, pair_cfg.H);
    [RC_L, ~] = sarvalid.generate_base_rc(signal, S60, pair_cfg.L);
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
    HPSNR(sample_idx) = h_metrics.psnr;
    HSSIM(sample_idx) = h_metrics.ssim;
    LPSNR(sample_idx) = l_metrics.psnr;
    LSSIM(sample_idx) = l_metrics.ssim;
    HEntropy(sample_idx) = h_metrics.entropy;
    LEntropy(sample_idx) = l_metrics.entropy;
    HOffSupport(sample_idx) = h_diag.off_support_ratio;
    LOffSupport(sample_idx) = l_diag.off_support_ratio;
    HRangeLeakage(sample_idx) = h_diag.range_leakage_ratio;
    LRangeLeakage(sample_idx) = l_diag.range_leakage_ratio;
    HAzimuthLeakage(sample_idx) = h_diag.azimuth_leakage_ratio;
    LAzimuthLeakage(sample_idx) = l_diag.azimuth_leakage_ratio;
end

DeltaPSNR = HPSNR - LPSNR;
DeltaSSIM = HSSIM - LSSIM;
detail = table(SampleID, Scene, HPSNR, HSSIM, LPSNR, LSSIM, ...
    DeltaPSNR, DeltaSSIM, HEntropy, LEntropy, HOffSupport, LOffSupport, ...
    HRangeLeakage, LRangeLeakage, HAzimuthLeakage, LAzimuthLeakage);

summary = struct();
names = ["HPSNR", "HSSIM", "LPSNR", "LSSIM", "DeltaPSNR", ...
    "DeltaSSIM", "HOffSupport", "LOffSupport"];
for name = names
    values = detail.(name);
    summary.(name + "_Mean") = mean(values, 'omitnan');
    summary.(name + "_Std") = std(values, 0, 'omitnan');
end
summary.SampleCount = num_samples;
evaluation = struct("summary", summary, "detail", detail);
end
