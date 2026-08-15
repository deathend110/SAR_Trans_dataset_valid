function outputs = run_generator_confirmation_c2( ...
        cfg, S60, development_manifest, c1)
%RUN_GENERATOR_CONFIRMATION_C2 严格匹配Range主方法并锁定辅助非零fa方法。

gc = cfg.generator_confirmation;
stage_dir = fullfile(gc.output_root, "stage_c2");
sarvalid.ensure_dir(stage_dir);
cache = sarvalid.load_stage_a_cache(development_manifest, S60, 512);
all_candidates = table();
all_seed_summary = table();
difficulty_matching = table();
locked_table = table();
locked_generators = cell(0, 1);

for pair_idx = 1:size(gc.hl_pairs, 1)
    q_high = gc.hl_pairs(pair_idx, 1);
    q_low = gc.hl_pairs(pair_idx, 2);
    task_dir = fullfile(stage_dir, pair_key(q_high, q_low));
    sarvalid.ensure_dir(task_dir);
    best_baru = c1.best_candidates( ...
        c1.best_candidates.QHigh == q_high & ...
        c1.best_candidates.QLow == q_low, :);
    if height(best_baru) ~= 1
        error('sarvalid:ConfirmationC1BestBARU', ...
            '每个倍率对必须恰好有一个C1 BARU锁定候选。');
    end

    checkpoint_path = string(fullfile(task_dir, "range_checkpoint.mat"));
    signature = c2_signature(cfg, S60, development_manifest, ...
        q_high, q_low, best_baru);
    initial = struct("candidate_results", table(), ...
        "seed_results", table(), "completed_keys", strings(0, 1));
    if gc.resume
        state = sarvalid.load_checkpoint(checkpoint_path, signature, initial);
    else
        state = initial;
        state.signature = signature;
    end

    coarse_pairs = enumerate_range_pairs( ...
        cfg, q_high, q_low, S60, [], "Range_2D_SFT");
    state = evaluate_list(state, coarse_pairs, "coarse", cache, ...
        S60, cfg, checkpoint_path);
    coarse_rows = range_rows(state.candidate_results);
    quality_anchor = select_range_quality(coarse_rows);
    closest_anchor = closest_difficulty(coarse_rows, best_baru, ...
        gc.strict_difficulty_tolerance);

    fine_pairs = [ ...
        enumerate_range_pairs(cfg, q_high, q_low, S60, ...
        quality_anchor, "Range_2D_SFT"); ...
        enumerate_range_pairs(cfg, q_high, q_low, S60, ...
        closest_anchor, "Range_2D_SFT")];
    state = evaluate_list(state, unique_pairs(fine_pairs), "fine", ...
        cache, S60, cfg, checkpoint_path);

    current_rows = range_rows(state.candidate_results);
    closest_anchor = closest_difficulty(current_rows, best_baru, ...
        gc.strict_difficulty_tolerance);
    micro_pairs = enumerate_micro_pairs( ...
        cfg, q_high, q_low, S60, closest_anchor, "Range_2D_SFT");
    state = evaluate_list(state, unique_pairs(micro_pairs), "micro", ...
        cache, S60, cfg, checkpoint_path);

    current_rows = range_rows(state.candidate_results);
    nonzero_rows = current_rows( ...
        current_rows.FaOverBa >= gc.nonzero_fa_min - 1e-12, :);
    if q_high == 2.5 && q_low == 1.5 && ~isempty(nonzero_rows)
        nonzero_anchor = closest_difficulty(nonzero_rows, best_baru, ...
            gc.strict_difficulty_tolerance);
        nonzero_micro = enumerate_micro_pairs( ...
            cfg, q_high, q_low, S60, nonzero_anchor, "Range_2D_SFT");
        nonzero_micro = filter_nonzero_pairs( ...
            nonzero_micro, gc.nonzero_fa_min);
        state = evaluate_list(state, unique_pairs(nonzero_micro), ...
            "micro_nonzero_fa", cache, S60, cfg, checkpoint_path);
    end

    candidates = range_rows(state.candidate_results);
    [matched_range, main_audit] = ...
        sarvalid.select_generator_match_strict( ...
        candidates, best_baru, gc.strict_difficulty_tolerance);
    main_audit = prefix_audit(main_audit, q_high, q_low, ...
        "severity_matched", "Range_2D_SFT");

    selected_rows = [matched_range; best_baru];
    roles = ["severity_matched"; "strong_baseline"];
    methods = ["Range_2D_SFT"; "BARU_RT"];

    if q_high == 2.5 && q_low == 1.5
        nonzero_rows = candidates( ...
            candidates.FaOverBa >= gc.nonzero_fa_min - 1e-12, :);
        [matched_nonzero, nonzero_audit] = ...
            sarvalid.select_generator_match_strict( ...
            nonzero_rows, best_baru, gc.strict_difficulty_tolerance);
        nonzero_audit = prefix_audit(nonzero_audit, q_high, q_low, ...
            "nonzero_fa_auxiliary", "Range_NonzeroFa_SFT");
        if nonzero_audit.DifficultyMatched
            matched_nonzero.Method = "Range_NonzeroFa_SFT";
            aux_pair = pair_from_row(cfg, matched_nonzero);
            matched_nonzero.PairKey = string(aux_pair.file_key);
            nonzero_audit.SelectedPairKey = string(aux_pair.file_key);
            selected_rows = [selected_rows; matched_nonzero]; %#ok<AGROW>
            roles = [roles; "nonzero_fa_auxiliary"]; %#ok<AGROW>
            methods = [methods; "Range_NonzeroFa_SFT"]; %#ok<AGROW>
        end
        difficulty_matching = append_table( ...
            difficulty_matching, nonzero_audit);
    end
    difficulty_matching = append_table(difficulty_matching, main_audit);

    pair_locks = cell(height(selected_rows), 1);
    for selected_idx = 1:height(selected_rows)
        selected_row = selected_rows(selected_idx, :);
        selected_row.Method = methods(selected_idx);
        pair = pair_from_row(cfg, selected_row);
        seeds = seed_families(cfg, methods(selected_idx));
        development = sarvalid.evaluate_generator_candidate( ...
            cache, S60, pair, seeds, cfg.normalization);
        difficulty_status = "not_applicable";
        if roles(selected_idx) == "severity_matched"
            difficulty_status = string(main_audit.Status);
        elseif roles(selected_idx) == "nonzero_fa_auxiliary"
            difficulty_status = string(nonzero_audit.Status);
        end
        pair_locks{selected_idx} = struct( ...
            "pair_cfg", pair, "norm_stats", development.norm_stats, ...
            "seed_families", seeds, "role", roles(selected_idx), ...
            "difficulty_status", difficulty_status, ...
            "pair_index", pair_idx);
        locked_generators{end+1, 1} = pair_locks{selected_idx}; %#ok<AGROW>
        locked_table = append_table(locked_table, locked_row( ...
            selected_row, roles(selected_idx), difficulty_status, cfg, S60));
    end

    writetable(candidates, fullfile(task_dir, "range_candidates.csv"));
    writetable(state.seed_results, ...
        fullfile(task_dir, "range_seed_summary.csv"));
    writetable(difficulty_matching( ...
        difficulty_matching.QHigh == q_high & ...
        difficulty_matching.QLow == q_low, :), ...
        fullfile(task_dir, "difficulty_matching.csv"));
    save(fullfile(task_dir, "stage_c2_pair.mat"), ...
        "selected_rows", "pair_locks", "main_audit", ...
        "candidates", "-v7.3");

    all_candidates = append_table(all_candidates, candidates);
    all_seed_summary = append_table(all_seed_summary, state.seed_results);
end

writetable(all_candidates, fullfile(stage_dir, "range_candidates.csv"));
writetable(all_seed_summary, fullfile(stage_dir, "range_seed_summary.csv"));
writetable(difficulty_matching, ...
    fullfile(stage_dir, "difficulty_matching.csv"));
writetable(locked_table, fullfile(stage_dir, "locked_generators.csv"));
main_rows = difficulty_matching.Role == "severity_matched";
StrictMatched = sum(main_rows) == size(gc.hl_pairs, 1) && ...
    all(difficulty_matching.DifficultyMatched(main_rows));
save(fullfile(stage_dir, "stage_c2_final.mat"), ...
    "locked_generators", "all_candidates", "all_seed_summary", ...
    "difficulty_matching", "locked_table", "StrictMatched", "-v7.3");

outputs = struct("locked_generators", {locked_generators}, ...
    "candidates", all_candidates, "seed_summary", all_seed_summary, ...
    "difficulty_matching", difficulty_matching, ...
    "locked_table", locked_table, "strict_matched", StrictMatched);
end

function pairs = enumerate_range_pairs( ...
        cfg, q_high, q_low, S60, anchor, method)
if isempty(anchor)
    grid = sarvalid.sft_candidate_grid( ...
        cfg, method, q_high, q_low, 1, S60);
else
    best = struct("STRdB", anchor.STRdB, ...
        "FrOverBr", anchor.FrOverBr, "FaOverBa", anchor.FaOverBa);
    grid = sarvalid.sft_candidate_grid( ...
        cfg, method, q_high, q_low, 1, S60, best);
end
pairs = pairs_from_grid(cfg, grid, q_high, q_low, method);
end

function pairs = enumerate_micro_pairs( ...
        cfg, q_high, q_low, S60, anchor, method)
micro_cfg = cfg;
micro_cfg.threshold.fine_STR_offsets_dB = ...
    cfg.generator_confirmation.range_micro_STR_offsets_dB;
micro_cfg.threshold.fine_frequency_offsets = ...
    cfg.generator_confirmation.range_micro_frequency_offsets;
best = struct("STRdB", anchor.STRdB, ...
    "FrOverBr", anchor.FrOverBr, "FaOverBa", anchor.FaOverBa);
grid = sarvalid.sft_candidate_grid( ...
    micro_cfg, method, q_high, q_low, 1, S60, best);
pairs = pairs_from_grid(cfg, grid, q_high, q_low, method);
end

function pairs = pairs_from_grid(cfg, grid, q_high, q_low, method)
pairs = cell(height(grid), 1);
for idx = 1:height(grid)
    threshold = make_threshold(cfg, cfg.threshold.As, ...
        grid.STRdB(idx), grid.FrOverBr(idx), grid.FaOverBa(idx));
    pair = sarvalid.make_pair_config( ...
        cfg, method, q_high, q_low, 1, threshold);
    pair.file_key = sarvalid.generator_file_key(pair, cfg.threshold_seed);
    pairs{idx} = pair;
end
end

function pairs = filter_nonzero_pairs(pairs, minimum)
keep = false(numel(pairs), 1);
for idx = 1:numel(pairs)
    keep(idx) = pairs{idx}.H.threshold.fa_over_Ba >= minimum - 1e-12;
end
pairs = pairs(keep);
end

function state = evaluate_list( ...
        state, pairs, stage, cache, S60, cfg, checkpoint_path)
for idx = 1:numel(pairs)
    pair = pairs{idx};
    key = string(pair.file_key);
    if any(state.completed_keys == key)
        continue;
    end
    seeds = cfg.threshold_seed;
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

function rows = range_rows(input)
rows = input(input.Method == "Range_2D_SFT", :);
end

function best = select_range_quality(rows)
rows = sortrows(rows, ["Pair_SSIM_Mean", "Pair_PSNR_Mean", ...
    "Worst_SSIM", "PairKey"], ...
    ["descend", "descend", "descend", "ascend"]);
best = rows(1, :);
end

function closest = closest_difficulty(rows, baru, tolerance)
distance = abs(rows.L_SSIM_Mean - baru.L_SSIM_Mean) / ...
    tolerance.l_ssim + ...
    abs(rows.Delta_SSIM_Mean - baru.Delta_SSIM_Mean) / ...
    tolerance.delta_ssim;
ranking = [distance, -rows.Worst_SSIM, ...
    -rows.Pair_SSIM_Mean, -rows.Pair_PSNR_Mean];
[~, order] = sortrows(ranking, [1, 2, 3, 4]);
closest = rows(order(1), :);
end

function output = unique_pairs(input)
if isempty(input)
    output = input;
    return;
end
keys = strings(numel(input), 1);
for idx = 1:numel(input)
    keys(idx) = input{idx}.file_key;
end
[~, keep] = unique(keys, 'stable');
output = input(sort(keep));
end

function pair = pair_from_row(cfg, row)
threshold = make_threshold(cfg, row.As, row.STRdB, ...
    row.FrOverBr, row.FaOverBa);
pair = sarvalid.make_pair_config(cfg, string(row.Method), ...
    row.QHigh, row.QLow, row.Alpha, threshold);
pair.file_key = sarvalid.generator_file_key( ...
    pair, seed_families(cfg, string(row.Method)));
end

function seeds = seed_families(cfg, method)
if method == "BARU_RT"
    seeds = cfg.generator_confirmation.rt_seed_families;
else
    seeds = cfg.threshold_seed;
end
end

function output = prefix_audit(input, q_high, q_low, role, method)
output = addvars(input, q_high, q_low, string(role), string(method), ...
    'Before', 1, 'NewVariableNames', ...
    ["QHigh", "QLow", "Role", "Method"]);
end

function row = locked_row(candidate, role, difficulty_status, cfg, S60)
pair = pair_from_row(cfg, candidate);
grid_h = sarvalid.resolve_acquisition(pair.H, [S60.nrn, S60.nan], S60);
grid_l = sarvalid.resolve_acquisition(pair.L, [S60.nrn, S60.nan], S60);
Method = string(pair.method);
PairKey = string(pair.file_key);
QHigh = candidate.QHigh;
QLow = candidate.QLow;
Alpha = candidate.Alpha;
As = candidate.As;
STRdB = candidate.STRdB;
FrOverBr = candidate.FrOverBr;
FaOverBa = candidate.FaOverBa;
Role = string(role);
DifficultyStatus = string(difficulty_status);
SeedFamilies = strjoin(string(seed_families(cfg, Method)), ";");
HRangeEff = grid_h.q_range_eff;
HAzimuthEff = grid_h.q_azimuth_eff;
HTotalEff = grid_h.q_total_eff;
LRangeEff = grid_l.q_range_eff;
LAzimuthEff = grid_l.q_azimuth_eff;
LTotalEff = grid_l.q_total_eff;
row = table(Method, PairKey, QHigh, QLow, Alpha, As, STRdB, ...
    FrOverBr, FaOverBa, Role, DifficultyStatus, SeedFamilies, ...
    HRangeEff, HAzimuthEff, HTotalEff, LRangeEff, LAzimuthEff, LTotalEff);
end

function signature = c2_signature( ...
        cfg, S60, manifest, q_high, q_low, best_baru)
gc = cfg.generator_confirmation;
signature = struct("experiment", gc.version, "stage", "C2", ...
    "q_high", q_high, "q_low", q_low, "best_baru", best_baru, ...
    "strict_tolerance", gc.strict_difficulty_tolerance, ...
    "micro_STR_offsets", gc.range_micro_STR_offsets_dB, ...
    "micro_frequency_offsets", gc.range_micro_frequency_offsets, ...
    "nonzero_fa_min", gc.nonzero_fa_min, ...
    "effective_grids", effective_range_grids(cfg, S60, q_high, q_low), ...
    "threshold", cfg.threshold, ...
    "manifest", manifest(:, ["SampleID", "Scene", "File", "CStart"]), ...
    "normalization", cfg.normalization, "imaging", imaging_signature(S60));
end

function output = effective_range_grids(cfg, S60, q_high, q_low)
threshold = make_threshold(cfg, cfg.threshold.As, 0, 0, 0);
pair = sarvalid.make_pair_config( ...
    cfg, "Range_2D_SFT", q_high, q_low, 1, threshold);
high = sarvalid.resolve_acquisition(pair.H, [S60.nrn, S60.nan], S60);
low = sarvalid.resolve_acquisition(pair.L, [S60.nrn, S60.nan], S60);
output = struct("H", compact_grid(high), "L", compact_grid(low));
end

function output = compact_grid(grid)
output = struct("q_total", grid.q_total, ...
    "q_range", grid.q_range, "q_azimuth", grid.q_azimuth, ...
    "q_range_eff", grid.q_range_eff, ...
    "q_azimuth_eff", grid.q_azimuth_eff, ...
    "q_total_eff", grid.q_total_eff, ...
    "upsampled_size", grid.upsampled_size, ...
    "Fs_up", grid.Fs_up, "PRF_up", grid.PRF_up);
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
