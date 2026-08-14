function evaluation = evaluate_pure_pair(cache, S60, pair_cfg, normalization_cfg)
%EVALUATE_PURE_PAIR 在开发缓存上联合评价纯H和纯L，并拟合全局归一化。

num_samples = numel(cache);
h_images = cell(num_samples, 1);
l_images = cell(num_samples, 1);
for sample_idx = 1:num_samples
    [RC_H, ~] = sarvalid.generate_base_rc(cache(sample_idx).signal, ...
        S60, pair_cfg.H);
    [RC_L, ~] = sarvalid.generate_base_rc(cache(sample_idx).signal, ...
        S60, pair_cfg.L);
    h_images{sample_idx} = single(sarvalid.focus_base_rc(RC_H, S60, 512));
    l_images{sample_idx} = single(sarvalid.focus_base_rc(RC_L, S60, 512));
end

Scene = strings(3 * num_samples, 1);
Modality = strings(3 * num_samples, 1);
Split = repmat("development", 3 * num_samples, 1);
Pixels = cell(3 * num_samples, 1);
for sample_idx = 1:num_samples
    rows = (sample_idx-1)*3 + (1:3);
    Scene(rows) = cache(sample_idx).scene;
    Modality(rows) = ["GT"; "H"; "L"];
    Pixels(rows) = {cache(sample_idx).gt_raw; h_images{sample_idx}; l_images{sample_idx}};
end
normalization_samples = table(Scene, Modality, Split, Pixels);
[norm_stats, norm_audit] = sarvalid.fit_global_normalization( ...
    normalization_samples, "development", ...
    LowPercentile=normalization_cfg.low_percentile, ...
    HighPercentile=normalization_cfg.high_percentile);

SampleID = zeros(num_samples, 1);
Scene = strings(num_samples, 1);
HPSNR = zeros(num_samples, 1);
HSSIM = zeros(num_samples, 1);
LPSNR = zeros(num_samples, 1);
LSSIM = zeros(num_samples, 1);
for sample_idx = 1:num_samples
    scene = cache(sample_idx).scene;
    gt = sarvalid.apply_normalization(cache(sample_idx).gt_raw, ...
        norm_stats, scene, "GT");
    h = sarvalid.apply_normalization(h_images{sample_idx}, ...
        norm_stats, scene, "H");
    l = sarvalid.apply_normalization(l_images{sample_idx}, ...
        norm_stats, scene, "L");
    SampleID(sample_idx) = cache(sample_idx).sample_id;
    Scene(sample_idx) = scene;
    HPSNR(sample_idx) = psnr(h, gt, 1);
    HSSIM(sample_idx) = ssim(h, gt, 'DynamicRange', 1);
    LPSNR(sample_idx) = psnr(l, gt, 1);
    LSSIM(sample_idx) = ssim(l, gt, 'DynamicRange', 1);
end
DeltaPSNR = HPSNR - LPSNR;
DeltaSSIM = HSSIM - LSSIM;
detail = table(SampleID, Scene, HPSNR, HSSIM, LPSNR, LSSIM, ...
    DeltaPSNR, DeltaSSIM);

summary = struct();
summary.H_PSNR_Mean = mean(HPSNR);
summary.H_SSIM_Mean = mean(HSSIM);
summary.L_PSNR_Mean = mean(LPSNR);
summary.L_SSIM_Mean = mean(LSSIM);
summary.Delta_PSNR_Mean = mean(DeltaPSNR);
summary.Delta_SSIM_Mean = mean(DeltaSSIM);
summary.Pair_PSNR_Mean = mean([HPSNR; LPSNR]);
summary.Pair_SSIM_Mean = mean([HSSIM; LSSIM]);
summary.SampleCount = num_samples;

evaluation = struct("summary", summary, "detail", detail, ...
    "norm_stats", norm_stats, "norm_audit", norm_audit);
end
