function evaluation = evaluate_generator_candidate( ...
        cache, S60, pair, seeds, norm_cfg)
%EVALUATE_GENERATOR_CANDIDATE 在开发集上评价一个生成器候选。

num_samples = numel(cache);
num_seeds = numel(seeds);
num_cases = num_samples * num_seeds;
h_raw = cell(num_cases, 1);
l_raw = cell(num_cases, 1);
case_sample = zeros(num_cases, 1);
case_seed = zeros(num_cases, 1);
ptr = 0;
for seed = seeds
    for sample_idx = 1:num_samples
        ptr = ptr + 1;
        sample_pair = pair;
        sample_id = cache(sample_idx).sample_id;
        sample_pair.H.seed = seed + sample_id * 1000;
        sample_pair.L.seed = seed + sample_id * 1000 + 1;
        RC_H = sarvalid.generate_base_rc( ...
            cache(sample_idx).signal, S60, sample_pair.H);
        RC_L = sarvalid.generate_base_rc( ...
            cache(sample_idx).signal, S60, sample_pair.L);
        h_raw{ptr} = single(sarvalid.focus_base_rc(RC_H, S60, 512));
        l_raw{ptr} = single(sarvalid.focus_base_rc(RC_L, S60, 512));
        case_sample(ptr) = sample_idx;
        case_seed(ptr) = seed;
    end
end

Scene = strings(3 * num_cases, 1);
Modality = strings(3 * num_cases, 1);
Split = repmat("development", 3 * num_cases, 1);
Pixels = cell(3 * num_cases, 1);
for case_idx = 1:num_cases
    sample_idx = case_sample(case_idx);
    rows = (case_idx-1)*3 + (1:3);
    Scene(rows) = cache(sample_idx).scene;
    Modality(rows) = ["GT"; "H"; "L"];
    Pixels(rows) = {cache(sample_idx).gt_raw; ...
        h_raw{case_idx}; l_raw{case_idx}};
end
[norm_stats, norm_audit] = sarvalid.fit_global_normalization( ...
    table(Scene, Modality, Split, Pixels), "development", ...
    LowPercentile=norm_cfg.low_percentile, ...
    HighPercentile=norm_cfg.high_percentile);

SampleID = zeros(num_cases, 1);
Scene = strings(num_cases, 1);
SeedFamily = case_seed;
HPSNR = zeros(num_cases, 1);
HSSIM = zeros(num_cases, 1);
LPSNR = zeros(num_cases, 1);
LSSIM = zeros(num_cases, 1);
for case_idx = 1:num_cases
    sample_idx = case_sample(case_idx);
    scene = cache(sample_idx).scene;
    gt = sarvalid.apply_normalization( ...
        cache(sample_idx).gt_raw, norm_stats, scene, "GT");
    high = sarvalid.apply_normalization( ...
        h_raw{case_idx}, norm_stats, scene, "H");
    low = sarvalid.apply_normalization( ...
        l_raw{case_idx}, norm_stats, scene, "L");
    HPSNR(case_idx) = psnr(high, gt, 1);
    HSSIM(case_idx) = ssim(high, gt, 'DynamicRange', 1);
    LPSNR(case_idx) = psnr(low, gt, 1);
    LSSIM(case_idx) = ssim(low, gt, 'DynamicRange', 1);
    SampleID(case_idx) = cache(sample_idx).sample_id;
    Scene(case_idx) = scene;
end
DeltaPSNR = HPSNR - LPSNR;
DeltaSSIM = HSSIM - LSSIM;
detail = table(SampleID, Scene, SeedFamily, HPSNR, HSSIM, ...
    LPSNR, LSSIM, DeltaPSNR, DeltaSSIM);
sample_detail = aggregate_samples(detail);
seed_summary = summarize_seeds(detail);
summary = summarize_samples(sample_detail, seed_summary);
evaluation = struct("detail", detail, "sample_detail", sample_detail, ...
    "seed_summary", seed_summary, "summary", summary, ...
    "norm_stats", norm_stats, "norm_audit", norm_audit);
end

function output = aggregate_samples(detail)
ids = unique(detail.SampleID, 'stable');
output = table();
numeric_names = ["HPSNR", "HSSIM", "LPSNR", "LSSIM", ...
    "DeltaPSNR", "DeltaSSIM"];
for id = ids.'
    rows = detail(detail.SampleID == id, :);
    row = table(rows.SampleID(1), rows.Scene(1), ...
        'VariableNames', {'SampleID', 'Scene'});
    for name = numeric_names
        row.(name) = mean(rows.(name));
        row.(name + "_SeedStd") = std(rows.(name), 0);
    end
    output = append_table(output, row);
end
end

function output = summarize_seeds(detail)
seeds = unique(detail.SeedFamily, 'stable');
output = table();
for seed = seeds.'
    rows = detail(detail.SeedFamily == seed, :);
    SeedFamily = seed;
    H_PSNR_Mean = mean(rows.HPSNR);
    H_SSIM_Mean = mean(rows.HSSIM);
    L_PSNR_Mean = mean(rows.LPSNR);
    L_SSIM_Mean = mean(rows.LSSIM);
    Delta_PSNR_Mean = mean(rows.DeltaPSNR);
    Delta_SSIM_Mean = mean(rows.DeltaSSIM);
    Pair_PSNR_Mean = mean([rows.HPSNR; rows.LPSNR]);
    Pair_SSIM_Mean = mean([rows.HSSIM; rows.LSSIM]);
    output = append_table(output, table(SeedFamily, H_PSNR_Mean, ...
        H_SSIM_Mean, L_PSNR_Mean, L_SSIM_Mean, ...
        Delta_PSNR_Mean, Delta_SSIM_Mean, ...
        Pair_PSNR_Mean, Pair_SSIM_Mean));
end
end

function summary = summarize_samples(detail, seed_summary)
summary = struct();
summary.H_PSNR_Mean = mean(detail.HPSNR);
summary.H_SSIM_Mean = mean(detail.HSSIM);
summary.L_PSNR_Mean = mean(detail.LPSNR);
summary.L_SSIM_Mean = mean(detail.LSSIM);
summary.Delta_PSNR_Mean = mean(detail.DeltaPSNR);
summary.Delta_SSIM_Mean = mean(detail.DeltaSSIM);
summary.Pair_PSNR_Mean = mean([detail.HPSNR; detail.LPSNR]);
summary.Pair_SSIM_Mean = mean([detail.HSSIM; detail.LSSIM]);
summary.Worst_SSIM = min([detail.HSSIM; detail.LSSIM]);
summary.Pair_SSIM_SeedStd = std(seed_summary.Pair_SSIM_Mean, 0);
summary.SampleCount = height(detail);
summary.SeedCount = height(seed_summary);
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
