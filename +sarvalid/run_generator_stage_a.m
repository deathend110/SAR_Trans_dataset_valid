function outputs = run_generator_stage_a(cfg, S60, manifest)
%RUN_GENERATOR_STAGE_A 搜索并验证Range+2D-SFT与BARU+RT生成器。

stage_dir = fullfile(cfg.generator_compare.output_root, "stage_a");
sarvalid.ensure_dir(stage_dir);
development_manifest = manifest(manifest.Split == "development", :);
verification_manifest = manifest(manifest.Split == "verification", :);
cache = sarvalid.load_stage_a_cache(development_manifest, S60, 512);

all_candidates = table();
all_candidate_seeds = table();
difficulty_matching = table();
locked_table = table();
verification_seed_detail = table();
verification_sample_detail = table();
verification_summary = table();
locked_generators = cell(0, 1);

for pair_idx = 1:size(cfg.generator_compare.hl_pairs, 1)
    q_high = cfg.generator_compare.hl_pairs(pair_idx, 1);
    q_low = cfg.generator_compare.hl_pairs(pair_idx, 2);
    pair_label = pair_key(q_high, q_low);
    pair_dir = fullfile(stage_dir, pair_label);
    sarvalid.ensure_dir(pair_dir);
    checkpoint_path = fullfile(pair_dir, "candidate_checkpoint.mat");
    signature = candidate_signature(cfg, S60, development_manifest, ...
        q_high, q_low);
    initial = struct("candidate_results", table(), ...
        "seed_results", table(), "completed_keys", strings(0, 1));
    if cfg.generator_compare.resume
        state = sarvalid.load_checkpoint( ...
            string(checkpoint_path), signature, initial);
    else
        state = initial;
        state.signature = signature;
    end

    baru_pairs = enumerate_baru_pairs(cfg, q_high, q_low);
    [state, baru_rows] = evaluate_candidate_list(state, baru_pairs, ...
        "coarse", cache, S60, cfg, checkpoint_path);
    best_baru = select_quality(baru_rows, true);

    range_coarse = enumerate_range_pairs(cfg, q_high, q_low, S60, []);
    [state, range_coarse_rows] = evaluate_candidate_list(state, ...
        range_coarse, "coarse", cache, S60, cfg, checkpoint_path);
    best_range_coarse = select_quality(range_coarse_rows, false);
    [matched_coarse, ~] = sarvalid.select_generator_match( ...
        range_coarse_rows, best_baru, ...
        cfg.generator_compare.difficulty_tolerance);

    fine_pairs = [ ...
        enumerate_range_pairs(cfg, q_high, q_low, S60, best_range_coarse); ...
        enumerate_range_pairs(cfg, q_high, q_low, S60, matched_coarse)];
    fine_pairs = unique_pairs(fine_pairs);
    [state, ~] = evaluate_candidate_list(state, fine_pairs, ...
        "fine", cache, S60, cfg, checkpoint_path);

    candidates = state.candidate_results;
    range_rows = candidates(candidates.Method == "Range_2D_SFT", :);
    baru_rows = candidates(candidates.Method == "BARU_RT", :);
    best_baru = select_quality(baru_rows, true);
    best_range_quality = select_quality(range_rows, false);
    [matched_range, match_audit] = sarvalid.select_generator_match( ...
        range_rows, best_baru, cfg.generator_compare.difficulty_tolerance);
    match_audit = addvars(match_audit, q_high, q_low, ...
        'Before', 1, 'NewVariableNames', ["QHigh", "QLow"]);

    writetable(candidates, fullfile(pair_dir, "candidate_results.csv"));
    writetable(state.seed_results, ...
        fullfile(pair_dir, "candidate_seed_summary.csv"));
    writetable(match_audit, fullfile(pair_dir, "difficulty_matching.csv"));

    selected_rows = [matched_range; best_baru];
    roles = ["severity_matched"; "strong_baseline"];
    pair_locks = cell(2, 1);
    for selected_idx = 1:2
        selected_row = selected_rows(selected_idx, :);
        selected_pair = pair_from_row(cfg, selected_row);
        seeds = seed_families(cfg, selected_row.Method);
        development = evaluate_candidate( ...
            cache, S60, selected_pair, seeds, cfg.normalization);
        pair_locks{selected_idx} = struct( ...
            "pair_cfg", selected_pair, ...
            "norm_stats", development.norm_stats, ...
            "seed_families", seeds, ...
            "role", roles(selected_idx), ...
            "difficulty_status", string(match_audit.Status), ...
            "pair_index", pair_idx);

        [seed_detail, sample_detail, summary] = verify_locked( ...
            verification_manifest, S60, pair_locks{selected_idx}, ...
            cfg, pair_dir);
        verification_seed_detail = append_table( ...
            verification_seed_detail, seed_detail);
        verification_sample_detail = append_table( ...
            verification_sample_detail, sample_detail);
        verification_summary = append_table(verification_summary, summary);
        locked_generators{end+1, 1} = pair_locks{selected_idx}; %#ok<AGROW>
    end

    quality_row = locked_row(best_range_quality, ...
        "quality_reference", string(match_audit.Status), cfg, S60);
    selected_lock_rows = [ ...
        locked_row(matched_range, "severity_matched", ...
        string(match_audit.Status), cfg, S60); ...
        locked_row(best_baru, "strong_baseline", ...
        string(match_audit.Status), cfg, S60)];
    locked_table = append_table(locked_table, ...
        [selected_lock_rows; quality_row]);
    difficulty_matching = append_table(difficulty_matching, match_audit);
    all_candidates = append_table(all_candidates, candidates);
    all_candidate_seeds = append_table(all_candidate_seeds, state.seed_results);

    save(fullfile(pair_dir, "stage_a_pair.mat"), ...
        "selected_rows", "best_range_quality", "match_audit", ...
        "pair_locks", "-v7.3");
end

writetable(all_candidates, fullfile(stage_dir, "all_candidates.csv"));
writetable(all_candidate_seeds, ...
    fullfile(stage_dir, "all_candidate_seed_summary.csv"));
writetable(difficulty_matching, ...
    fullfile(stage_dir, "difficulty_matching.csv"));
writetable(locked_table, fullfile(stage_dir, "locked_generators.csv"));
writetable(verification_seed_detail, ...
    fullfile(stage_dir, "verification_detail.csv"));
writetable(verification_sample_detail, ...
    fullfile(stage_dir, "verification_sample_aggregate.csv"));
writetable(verification_summary, ...
    fullfile(stage_dir, "verification_summary.csv"));
save(fullfile(stage_dir, "stage_a_final.mat"), ...
    "locked_generators", "all_candidates", "all_candidate_seeds", ...
    "difficulty_matching", "locked_table", ...
    "verification_seed_detail", "verification_sample_detail", ...
    "verification_summary", "-v7.3");

outputs = struct("locked_generators", {locked_generators}, ...
    "candidates", all_candidates, ...
    "candidate_seed_summary", all_candidate_seeds, ...
    "difficulty_matching", difficulty_matching, ...
    "locked_table", locked_table, ...
    "verification_seed_detail", verification_seed_detail, ...
    "verification_sample_detail", verification_sample_detail, ...
    "verification_summary", verification_summary);
end

function signature = candidate_signature(cfg, S60, manifest, q_high, q_low)
signature = struct( ...
    "experiment", cfg.experiment_name + "_generator_compare", ...
    "stage", "generator_stage_a", ...
    "q_high", q_high, "q_low", q_low, ...
    "methods", cfg.generator_compare.methods, ...
    "baru_alpha", cfg.generator_compare.baru_alpha, ...
    "baru_As", cfg.generator_compare.baru_As, ...
    "rt_seed_families", cfg.generator_compare.rt_seed_families, ...
    "effective_grids", effective_grid_signature( ...
        cfg, q_high, q_low, S60), ...
    "threshold", cfg.threshold, ...
    "difficulty_tolerance", cfg.generator_compare.difficulty_tolerance, ...
    "manifest", manifest(:, ["SampleID", "Scene", "File", "CStart"]), ...
    "normalization", cfg.normalization, ...
    "imaging", imaging_signature(S60));
end

function pairs = enumerate_baru_pairs(cfg, q_high, q_low)
pairs = cell(numel(cfg.generator_compare.baru_alpha) * ...
    numel(cfg.generator_compare.baru_As), 1);
ptr = 0;
for alpha = cfg.generator_compare.baru_alpha
    for As = cfg.generator_compare.baru_As
        ptr = ptr + 1;
        threshold = make_threshold(cfg, As, NaN, 0, 0);
        pair = sarvalid.make_pair_config( ...
            cfg, "BARU_RT", q_high, q_low, alpha, threshold);
        pair.file_key = sarvalid.generator_file_key( ...
            pair, cfg.generator_compare.rt_seed_families);
        pairs{ptr} = pair;
    end
end
end

function pairs = enumerate_range_pairs(cfg, q_high, q_low, S60, anchor)
if isempty(anchor)
    grid = sarvalid.sft_candidate_grid( ...
        cfg, "Range_2D_SFT", q_high, q_low, 1, S60);
else
    best = struct("STRdB", anchor.STRdB, ...
        "FrOverBr", anchor.FrOverBr, "FaOverBa", anchor.FaOverBa);
    grid = sarvalid.sft_candidate_grid( ...
        cfg, "Range_2D_SFT", q_high, q_low, 1, S60, best);
end
pairs = cell(height(grid), 1);
for idx = 1:height(grid)
    threshold = make_threshold(cfg, cfg.threshold.As, ...
        grid.STRdB(idx), grid.FrOverBr(idx), grid.FaOverBa(idx));
    pair = sarvalid.make_pair_config( ...
        cfg, "Range_2D_SFT", q_high, q_low, 1, threshold);
    pair.file_key = sarvalid.generator_file_key(pair, cfg.threshold_seed);
    pairs{idx} = pair;
end
end

function threshold = make_threshold(cfg, As, STR, fr, fa)
threshold = struct("As", As, "STR_dB", STR, ...
    "fr_over_Br", fr, "fa_over_Ba", fa, ...
    "phi0", cfg.threshold.phi0);
end

function pairs = unique_pairs(pairs)
if isempty(pairs)
    return;
end
keys = strings(numel(pairs), 1);
for idx = 1:numel(pairs)
    keys(idx) = pairs{idx}.file_key;
end
[~, keep] = unique(keys, 'stable');
pairs = pairs(sort(keep));
end

function [state, rows] = evaluate_candidate_list( ...
        state, pairs, stage, cache, S60, cfg, checkpoint_path)
rows = table();
for idx = 1:numel(pairs)
    pair = pairs{idx};
    key = string(pair.file_key);
    existing = find(state.completed_keys == key, 1);
    if isempty(existing)
        seeds = seed_families(cfg, string(pair.method));
        evaluation = evaluate_candidate(cache, S60, pair, seeds, cfg.normalization);
        row = candidate_row(pair, stage, evaluation, seeds);
        seed_rows = prefix_seed_summary(evaluation.seed_summary, pair, stage);
        state.candidate_results = append_table(state.candidate_results, row);
        state.seed_results = append_table(state.seed_results, seed_rows);
        state.completed_keys(end+1, 1) = key;
        sarvalid.atomic_save(string(checkpoint_path), struct("state", state));
    else
        row = state.candidate_results( ...
            state.candidate_results.PairKey == key, :);
    end
    rows = append_table(rows, row);
end
end

function evaluation = evaluate_candidate(cache, S60, pair, seeds, norm_cfg)
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
        RC_H = sarvalid.generate_base_rc(cache(sample_idx).signal, S60, sample_pair.H);
        RC_L = sarvalid.generate_base_rc(cache(sample_idx).signal, S60, sample_pair.L);
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
    Pixels(rows) = {cache(sample_idx).gt_raw; h_raw{case_idx}; l_raw{case_idx}};
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
sample_detail = aggregate_development_samples(detail);
seed_summary = summarize_development_seeds(detail);
summary = summarize_development_samples(sample_detail, seed_summary);
evaluation = struct("detail", detail, "sample_detail", sample_detail, ...
    "seed_summary", seed_summary, "summary", summary, ...
    "norm_stats", norm_stats, "norm_audit", norm_audit);
end

function output = aggregate_development_samples(detail)
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

function output = summarize_development_seeds(detail)
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

function summary = summarize_development_samples(detail, seed_summary)
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

function row = candidate_row(pair, stage, evaluation, seeds)
s = evaluation.summary;
threshold = pair.H.threshold;
Method = string(pair.method);
PairKey = string(pair.file_key);
Stage = string(stage);
QHigh = pair.q_high;
QLow = pair.q_low;
Alpha = pair.alpha;
As = threshold.As;
STRdB = threshold.STR_dB;
FrOverBr = threshold.fr_over_Br;
FaOverBa = threshold.fa_over_Ba;
H_PSNR_Mean = s.H_PSNR_Mean;
H_SSIM_Mean = s.H_SSIM_Mean;
L_PSNR_Mean = s.L_PSNR_Mean;
L_SSIM_Mean = s.L_SSIM_Mean;
Delta_PSNR_Mean = s.Delta_PSNR_Mean;
Delta_SSIM_Mean = s.Delta_SSIM_Mean;
Pair_PSNR_Mean = s.Pair_PSNR_Mean;
Pair_SSIM_Mean = s.Pair_SSIM_Mean;
Worst_SSIM = s.Worst_SSIM;
Pair_SSIM_SeedStd = s.Pair_SSIM_SeedStd;
SampleCount = s.SampleCount;
SeedCount = s.SeedCount;
SeedFamilies = strjoin(string(seeds), ";");
row = table(Method, PairKey, Stage, QHigh, QLow, Alpha, As, ...
    STRdB, FrOverBr, FaOverBa, H_PSNR_Mean, H_SSIM_Mean, ...
    L_PSNR_Mean, L_SSIM_Mean, Delta_PSNR_Mean, Delta_SSIM_Mean, ...
    Pair_PSNR_Mean, Pair_SSIM_Mean, Worst_SSIM, ...
    Pair_SSIM_SeedStd, SampleCount, SeedCount, SeedFamilies);
end

function output = prefix_seed_summary(input, pair, stage)
count = height(input);
output = addvars(input, ...
    repmat(string(pair.method), count, 1), ...
    repmat(string(pair.file_key), count, 1), ...
    repmat(string(stage), count, 1), ...
    repmat(pair.q_high, count, 1), repmat(pair.q_low, count, 1), ...
    repmat(pair.alpha, count, 1), repmat(pair.H.threshold.As, count, 1), ...
    'Before', 1, 'NewVariableNames', ...
    ["Method", "PairKey", "Stage", "QHigh", "QLow", "Alpha", "As"]);
end

function best = select_quality(rows, is_baru)
valid = isfinite(rows.Pair_SSIM_Mean) & isfinite(rows.Pair_PSNR_Mean);
rows = rows(valid, :);
if isempty(rows)
    error('sarvalid:NoGeneratorCandidate', '没有有限的生成器候选。');
end
if is_baru
    ranking = [-rows.Pair_SSIM_Mean, -rows.Pair_PSNR_Mean, ...
        abs(rows.As - 0.6), rows.Alpha];
    columns = [1, 2, 3, 4];
else
    ranking = [-rows.Pair_SSIM_Mean, -rows.Pair_PSNR_Mean, ...
        -rows.Worst_SSIM, abs(rows.STRdB), rows.FrOverBr + rows.FaOverBa];
    columns = 1:size(ranking, 2);
end
[~, order] = sortrows(ranking, columns);
best = rows(order(1), :);
end

function pair = pair_from_row(cfg, row)
threshold = make_threshold(cfg, row.As, row.STRdB, ...
    row.FrOverBr, row.FaOverBa);
pair = sarvalid.make_pair_config(cfg, row.Method, row.QHigh, ...
    row.QLow, row.Alpha, threshold);
pair.file_key = string(row.PairKey);
end

function [seed_detail, sample_detail, summary_row] = verify_locked( ...
        manifest, S60, lock, cfg, pair_dir)
pair = lock.pair_cfg;
seed_detail = table();
for seed_idx = 1:numel(lock.seed_families)
    seed = lock.seed_families(seed_idx);
    seeded_pair = pair;
    seeded_pair.H.seed = seed;
    seeded_pair.L.seed = seed;
    seed_key = "seed_" + encode(seed);
    checkpoint = struct( ...
        "path", string(fullfile(pair_dir, ...
        string(pair.file_key) + "_" + seed_key + "_verification.mat")), ...
        "signature", struct("stage", "generator_verification", ...
        "pair", seeded_pair, "seed_family", seed, ...
        "rt_seed_families", cfg.generator_compare.rt_seed_families, ...
        "effective_grid_H", compact_grid_signature( ...
            sarvalid.resolve_acquisition(seeded_pair.H, ...
            [S60.nrn, S60.nan], S60)), ...
        "effective_grid_L", compact_grid_signature( ...
            sarvalid.resolve_acquisition(seeded_pair.L, ...
            [S60.nrn, S60.nan], S60)), ...
        "manifest", manifest(:, ["SampleID", "Scene", "File", "CStart"]), ...
        "normalization", lock.norm_stats, ...
        "imaging", imaging_signature(S60)), ...
        "resume", cfg.generator_compare.resume);
    diagnostic_dir = "";
    if seed_idx == 1
        diagnostic_dir = fullfile(pair_dir, "diagnostics", pair.method);
    end
    evaluation = sarvalid.verify_pure_pair(manifest, S60, seeded_pair, ...
        lock.norm_stats, cfg.diagnostics, diagnostic_dir, checkpoint);
    rows = evaluation.detail;
    count = height(rows);
    rows = addvars(rows, repmat(string(pair.method), count, 1), ...
        repmat(string(pair.file_key), count, 1), ...
        repmat(pair.q_high, count, 1), repmat(pair.q_low, count, 1), ...
        repmat(pair.alpha, count, 1), repmat(pair.H.threshold.As, count, 1), ...
        repmat(seed, count, 1), 'Before', 1, 'NewVariableNames', ...
        ["Method", "PairKey", "QHigh", "QLow", "Alpha", "As", "SeedFamily"]);
    seed_detail = append_table(seed_detail, rows);
end
sample_detail = aggregate_verification_samples(seed_detail);
summary_row = verification_summary_row(pair, sample_detail, lock);
end

function output = aggregate_verification_samples(input)
ids = unique(input.SampleID, 'stable');
output = table();
key_names = ["Method", "PairKey", "QHigh", "QLow", "Alpha", "As", ...
    "SampleID", "Scene"];
numeric_names = setdiff(string(input.Properties.VariableNames), ...
    [key_names, "SeedFamily"], 'stable');
for id = ids.'
    rows = input(input.SampleID == id, :);
    row = rows(1, key_names);
    for name = numeric_names
        row.(name) = mean(rows.(name));
        row.(name + "_SeedStd") = std(rows.(name), 0);
    end
    output = append_table(output, row);
end
end

function row = verification_summary_row(pair, detail, lock)
Method = string(pair.method);
PairKey = string(pair.file_key);
QHigh = pair.q_high;
QLow = pair.q_low;
Alpha = pair.alpha;
As = pair.H.threshold.As;
Role = string(lock.role);
DifficultyStatus = string(lock.difficulty_status);
SampleCount = height(detail);
SeedCount = numel(lock.seed_families);
MeanPSNR = mean([detail.HPSNR; detail.LPSNR]);
MeanSSIM = mean([detail.HSSIM; detail.LSSIM]);
WorstPSNR = min([detail.HPSNR; detail.LPSNR]);
WorstSSIM = min([detail.HSSIM; detail.LSSIM]);
HPSNR = mean(detail.HPSNR);
HSSIM = mean(detail.HSSIM);
LPSNR = mean(detail.LPSNR);
LSSIM = mean(detail.LSSIM);
DeltaPSNR = mean(detail.DeltaPSNR);
DeltaSSIM = mean(detail.DeltaSSIM);
GradientRMSE = mean([detail.HGradientRMSE; detail.LGradientRMSE]);
BrightScattererError = mean([detail.HBrightScattererError; ...
    detail.LBrightScattererError]);
OffSupportRatio = mean([detail.HOffSupport; detail.LOffSupport]);
RangeLeakageRatio = mean([detail.HRangeLeakage; detail.LRangeLeakage]);
AzimuthLeakageRatio = mean([detail.HAzimuthLeakage; detail.LAzimuthLeakage]);
row = table(Method, PairKey, QHigh, QLow, Alpha, As, Role, ...
    DifficultyStatus, SampleCount, SeedCount, MeanPSNR, MeanSSIM, ...
    WorstPSNR, WorstSSIM, HPSNR, HSSIM, LPSNR, LSSIM, ...
    DeltaPSNR, DeltaSSIM, GradientRMSE, BrightScattererError, ...
    OffSupportRatio, RangeLeakageRatio, AzimuthLeakageRatio);
end

function row = locked_row(candidate, role, difficulty_status, cfg, S60)
pair_method = string(candidate.Method);
threshold = struct("As", candidate.As, "STR_dB", candidate.STRdB, ...
    "fr_over_Br", candidate.FrOverBr, "fa_over_Ba", candidate.FaOverBa, ...
    "phi0", cfg.threshold.phi0);
pair = sarvalid.make_pair_config(cfg, pair_method, ...
    candidate.QHigh, candidate.QLow, candidate.Alpha, threshold);
grid_h = sarvalid.resolve_acquisition(pair.H, [S60.nrn, S60.nan], S60);
grid_l = sarvalid.resolve_acquisition(pair.L, [S60.nrn, S60.nan], S60);
Method = pair_method;
PairKey = string(candidate.PairKey);
QHigh = candidate.QHigh;
QLow = candidate.QLow;
Alpha = candidate.Alpha;
As = candidate.As;
STRdB = candidate.STRdB;
FrOverBr = candidate.FrOverBr;
FaOverBa = candidate.FaOverBa;
Role = string(role);
DifficultyStatus = string(difficulty_status);
SeedFamilies = strjoin(string(seed_families(cfg, pair_method)), ";");
HRangeEff = grid_h.q_range_eff;
HAzimuthEff = grid_h.q_azimuth_eff;
HTotalEff = grid_h.q_total_eff;
LRangeEff = grid_l.q_range_eff;
LAzimuthEff = grid_l.q_azimuth_eff;
LTotalEff = grid_l.q_total_eff;
row = table(Method, PairKey, QHigh, QLow, Alpha, As, STRdB, ...
    FrOverBr, FaOverBa, Role, DifficultyStatus, SeedFamilies, HRangeEff, ...
    HAzimuthEff, HTotalEff, LRangeEff, LAzimuthEff, LTotalEff);
end

function signature = effective_grid_signature(cfg, q_high, q_low, S60)
methods = cfg.generator_compare.methods(:);
alphas = [1; cfg.generator_compare.baru_alpha(:)];
method_rows = ["Range_2D_SFT"; repmat("BARU_RT", ...
    numel(cfg.generator_compare.baru_alpha), 1)];
row_count = numel(alphas);
Method = strings(row_count, 1);
Alpha = zeros(row_count, 1);
HRangeEff = zeros(row_count, 1);
HAzimuthEff = zeros(row_count, 1);
HTotalEff = zeros(row_count, 1);
LRangeEff = zeros(row_count, 1);
LAzimuthEff = zeros(row_count, 1);
LTotalEff = zeros(row_count, 1);
threshold = make_threshold(cfg, cfg.threshold.As, 0, 0, 0);
for idx = 1:row_count
    pair = sarvalid.make_pair_config(cfg, method_rows(idx), ...
        q_high, q_low, alphas(idx), threshold);
    high = sarvalid.resolve_acquisition(pair.H, [S60.nrn, S60.nan], S60);
    low = sarvalid.resolve_acquisition(pair.L, [S60.nrn, S60.nan], S60);
    Method(idx) = method_rows(idx);
    Alpha(idx) = pair.alpha;
    HRangeEff(idx) = high.q_range_eff;
    HAzimuthEff(idx) = high.q_azimuth_eff;
    HTotalEff(idx) = high.q_total_eff;
    LRangeEff(idx) = low.q_range_eff;
    LAzimuthEff(idx) = low.q_azimuth_eff;
    LTotalEff(idx) = low.q_total_eff;
end
signature = table(Method, Alpha, HRangeEff, HAzimuthEff, ...
    HTotalEff, LRangeEff, LAzimuthEff, LTotalEff);
if ~all(ismember(methods, unique(Method)))
    error('sarvalid:GeneratorGridSignature', '生成器方法未完整写入网格签名。');
end
end

function seeds = seed_families(cfg, method)
if method == "BARU_RT"
    seeds = cfg.generator_compare.rt_seed_families;
else
    seeds = cfg.threshold_seed;
end
end

function key = pair_key(q_high, q_low)
key = "qh" + encode(q_high) + "_ql" + encode(q_low);
end

function value = encode(number)
value = string(sprintf('%.12g', number));
value = replace(value, "-", "m");
value = replace(value, ".", "p");
value = replace(value, "+", "");
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end

function signature = imaging_signature(S60)
names = ["fc", "B", "Fs", "prf", "R0", "C", "v", ...
    "Tp", "Ta", "nrn", "nan", "R_total", "A_num"];
signature = struct();
for name = names
    if isfield(S60, name)
        signature.(name) = S60.(name);
    end
end
end

function compact = compact_grid_signature(grid)
compact = struct("q_total", grid.q_total, ...
    "q_range", grid.q_range, "q_azimuth", grid.q_azimuth, ...
    "q_range_eff", grid.q_range_eff, ...
    "q_azimuth_eff", grid.q_azimuth_eff, ...
    "q_total_eff", grid.q_total_eff, ...
    "upsampled_size", grid.upsampled_size, ...
    "Fs_up", grid.Fs_up, "PRF_up", grid.PRF_up);
end
