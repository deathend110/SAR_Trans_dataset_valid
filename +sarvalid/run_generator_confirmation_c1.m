function outputs = run_generator_confirmation_c1( ...
        cfg, S60, development_manifest)
%RUN_GENERATOR_CONFIRMATION_C1 扩展BARU网格并审计搜索边界。

gc = cfg.generator_confirmation;
stage_dir = fullfile(gc.output_root, "stage_c1");
sarvalid.ensure_dir(stage_dir);
cache = sarvalid.load_stage_a_cache(development_manifest, S60, 512);
all_candidates = table();
all_seed_summary = table();
boundary_audit = table();
best_candidates = table();

for pair_idx = 1:size(gc.hl_pairs, 1)
    q_high = gc.hl_pairs(pair_idx, 1);
    q_low = gc.hl_pairs(pair_idx, 2);
    task_dir = fullfile(stage_dir, pair_key(q_high, q_low));
    sarvalid.ensure_dir(task_dir);
    checkpoint_path = string(fullfile(task_dir, "candidate_checkpoint.mat"));
    signature = c1_signature(cfg, S60, development_manifest, q_high, q_low);
    initial = struct("candidate_results", table(), ...
        "seed_results", table(), "completed_keys", strings(0, 1));
    if gc.resume
        state = sarvalid.load_checkpoint(checkpoint_path, signature, initial);
    else
        state = initial;
        state.signature = signature;
    end

    coarse_pairs = enumerate_baru_pairs(cfg, q_high, q_low, ...
        gc.baru_coarse_alpha, gc.baru_coarse_As);
    state = evaluate_list(state, coarse_pairs, "coarse", cache, ...
        S60, cfg, checkpoint_path);
    coarse_rows = state.candidate_results( ...
        state.candidate_results.Stage == "coarse", :);
    coarse_best = select_baru_quality(coarse_rows);

    alpha_values = bounded_values(coarse_best.Alpha + ...
        gc.baru_fine_offsets, gc.baru_alpha_bounds);
    As_values = bounded_values(coarse_best.As + ...
        gc.baru_fine_offsets, gc.baru_As_bounds);
    % 粗搜索若落在边缘，细化网格必须显式触达对应硬边界。
    if coarse_best.Alpha == min(gc.baru_coarse_alpha)
        alpha_values = bounded_values( ...
            [alpha_values, gc.baru_alpha_bounds(1)], gc.baru_alpha_bounds);
    elseif coarse_best.Alpha == max(gc.baru_coarse_alpha)
        alpha_values = bounded_values( ...
            [alpha_values, gc.baru_alpha_bounds(2)], gc.baru_alpha_bounds);
    end
    if coarse_best.As == min(gc.baru_coarse_As)
        As_values = bounded_values( ...
            [As_values, gc.baru_As_bounds(1)], gc.baru_As_bounds);
    elseif coarse_best.As == max(gc.baru_coarse_As)
        As_values = bounded_values( ...
            [As_values, gc.baru_As_bounds(2)], gc.baru_As_bounds);
    end
    fine_pairs = enumerate_baru_pairs(cfg, q_high, q_low, ...
        alpha_values, As_values);
    state = evaluate_list(state, fine_pairs, "fine", cache, ...
        S60, cfg, checkpoint_path);

    candidates = state.candidate_results;
    best = select_baru_quality(candidates);
    audit = sarvalid.audit_baru_boundary( ...
        best, candidates, gc, q_high, q_low);
    writetable(candidates, fullfile(task_dir, "baru_candidates.csv"));
    writetable(state.seed_results, ...
        fullfile(task_dir, "baru_seed_summary.csv"));
    writetable(audit, fullfile(task_dir, "boundary_audit.csv"));
    save(fullfile(task_dir, "stage_c1_pair.mat"), ...
        "best", "audit", "candidates", "-v7.3");

    all_candidates = append_table(all_candidates, candidates);
    all_seed_summary = append_table(all_seed_summary, state.seed_results);
    boundary_audit = append_table(boundary_audit, audit);
    best_candidates = append_table(best_candidates, best);
end

writetable(all_candidates, fullfile(stage_dir, "baru_candidates.csv"));
writetable(all_seed_summary, fullfile(stage_dir, "baru_seed_summary.csv"));
writetable(boundary_audit, fullfile(stage_dir, "boundary_audit.csv"));
SearchClosed = all(boundary_audit.SearchClosed);
save(fullfile(stage_dir, "stage_c1_final.mat"), ...
    "all_candidates", "all_seed_summary", "boundary_audit", ...
    "best_candidates", "SearchClosed", "-v7.3");

outputs = struct("candidates", all_candidates, ...
    "seed_summary", all_seed_summary, ...
    "boundary_audit", boundary_audit, ...
    "best_candidates", best_candidates, ...
    "search_closed", SearchClosed);
end

function pairs = enumerate_baru_pairs(cfg, q_high, q_low, alphas, amplitudes)
pairs = cell(numel(alphas) * numel(amplitudes), 1);
ptr = 0;
for alpha = alphas
    for As = amplitudes
        ptr = ptr + 1;
        threshold = make_threshold(cfg, As, NaN, 0, 0);
        pair = sarvalid.make_pair_config( ...
            cfg, "BARU_RT", q_high, q_low, alpha, threshold);
        pair.file_key = sarvalid.generator_file_key( ...
            pair, cfg.generator_confirmation.rt_seed_families);
        pairs{ptr} = pair;
    end
end
end

function state = evaluate_list( ...
        state, pairs, stage, cache, S60, cfg, checkpoint_path)
for idx = 1:numel(pairs)
    pair = pairs{idx};
    key = string(pair.file_key);
    if any(state.completed_keys == key)
        continue;
    end
    seeds = cfg.generator_confirmation.rt_seed_families;
    evaluation = sarvalid.evaluate_generator_candidate( ...
        cache, S60, pair, seeds, cfg.normalization);
    [row, seed_rows] = sarvalid.generator_candidate_row( ...
        pair, stage, evaluation, seeds);
    state.candidate_results = append_table(state.candidate_results, row);
    state.seed_results = append_table(state.seed_results, seed_rows);
    state.completed_keys(end+1, 1) = key;
    sarvalid.atomic_save(checkpoint_path, struct("state", state));
end
end

function best = select_baru_quality(rows)
valid = isfinite(rows.Pair_SSIM_Mean) & ...
    isfinite(rows.Pair_PSNR_Mean) & isfinite(rows.Pair_SSIM_SeedStd);
rows = rows(valid, :);
if isempty(rows)
    error('sarvalid:NoConfirmationBARUCandidate', ...
        '没有有限的BARU确认候选。');
end
rows = sortrows(rows, ["Pair_SSIM_Mean", "Pair_PSNR_Mean", ...
    "Pair_SSIM_SeedStd", "PairKey"], ...
    ["descend", "descend", "ascend", "ascend"]);
best = rows(1, :);
end

function values = bounded_values(values, bounds)
values = unique(round(values(:).', 10));
values = values(values >= bounds(1) & values <= bounds(2));
end

function signature = c1_signature(cfg, S60, manifest, q_high, q_low)
gc = cfg.generator_confirmation;
signature = struct("experiment", gc.version, "stage", "C1", ...
    "q_high", q_high, "q_low", q_low, ...
    "coarse_alpha", gc.baru_coarse_alpha, ...
    "coarse_As", gc.baru_coarse_As, ...
    "fine_offsets", gc.baru_fine_offsets, ...
    "alpha_bounds", gc.baru_alpha_bounds, ...
    "As_bounds", gc.baru_As_bounds, ...
    "boundary_gain_tolerance", gc.baru_boundary_gain_tolerance, ...
    "rt_seed_families", gc.rt_seed_families, ...
    "effective_grids", effective_baru_grids(cfg, S60, q_high, q_low), ...
    "manifest", manifest(:, ["SampleID", "Scene", "File", "CStart"]), ...
    "normalization", cfg.normalization, "threshold", cfg.threshold, ...
    "imaging", imaging_signature(S60));
end

function output = effective_baru_grids(cfg, S60, q_high, q_low)
gc = cfg.generator_confirmation;
alphas = unique([gc.baru_coarse_alpha, ...
    gc.baru_alpha_bounds(1):0.05:gc.baru_alpha_bounds(2)]).';
count = numel(alphas);
Alpha = zeros(count, 1);
HRangeEff = zeros(count, 1);
HAzimuthEff = zeros(count, 1);
HTotalEff = zeros(count, 1);
LRangeEff = zeros(count, 1);
LAzimuthEff = zeros(count, 1);
LTotalEff = zeros(count, 1);
threshold = make_threshold(cfg, gc.baru_coarse_As(1), NaN, 0, 0);
for idx = 1:count
    pair = sarvalid.make_pair_config( ...
        cfg, "BARU_RT", q_high, q_low, alphas(idx), threshold);
    high = sarvalid.resolve_acquisition(pair.H, [S60.nrn, S60.nan], S60);
    low = sarvalid.resolve_acquisition(pair.L, [S60.nrn, S60.nan], S60);
    Alpha(idx) = alphas(idx);
    HRangeEff(idx) = high.q_range_eff;
    HAzimuthEff(idx) = high.q_azimuth_eff;
    HTotalEff(idx) = high.q_total_eff;
    LRangeEff(idx) = low.q_range_eff;
    LAzimuthEff(idx) = low.q_azimuth_eff;
    LTotalEff(idx) = low.q_total_eff;
end
output = table(Alpha, HRangeEff, HAzimuthEff, HTotalEff, ...
    LRangeEff, LAzimuthEff, LTotalEff);
end

function threshold = make_threshold(cfg, As, STR, fr, fa)
threshold = struct("As", As, "STR_dB", STR, ...
    "fr_over_Br", fr, "fa_over_Ba", fa, ...
    "phi0", cfg.threshold.phi0);
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

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
