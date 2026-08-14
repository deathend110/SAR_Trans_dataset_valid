function outputs = run_stage_a_screening(cfg)
%RUN_STAGE_A_SCREENING 运行四类SAR 1-bit纯H/L退化模型筛选。
%
% 默认配置会执行完整搜索。仅检查清单和配置时，请先设置：
%   cfg = sarvalid.default_config(); cfg.runtime.dry_run = true;

arguments
    cfg (1, 1) struct = sarvalid.default_config()
end

addpath(cfg.repo_root);
sarvalid.ensure_dir(cfg.stage_a.output_dir);
S60 = load(cfg.parameter_file_60);
manifest = sarvalid.build_stage_a_manifest(cfg, S60);
writetable(manifest, fullfile(cfg.stage_a.output_dir, "stage_a_manifest.csv"));
sarvalid.write_json(fullfile(cfg.stage_a.output_dir, "config.json"), cfg);
save(fullfile(cfg.stage_a.output_dir, "config.mat"), "cfg", "S60");

develop_manifest = manifest(string(manifest.Split) == "development", :);
verify_manifest = manifest(string(manifest.Split) == "verification", :);
if cfg.runtime.dry_run
    outputs = struct("cfg", cfg, "manifest", manifest, ...
        "candidate_results", table(), "locked", table());
    fprintf('Stage A dry-run完成：开发样本%d，验证样本%d。\n', ...
        height(develop_manifest), height(verify_manifest));
    return;
end

fprintf('加载Stage A开发缓存：%d个样本。\n', height(develop_manifest));
development_cache = sarvalid.load_stage_a_cache(develop_manifest, S60, 512);

all_candidates = table();
locked_rows = table();
locked_configs = cell(0, 1);
verification_summaries = table();

for method_idx = 1:numel(cfg.methods)
    method = cfg.methods(method_idx);
    for pair_idx = 1:size(cfg.hl_pairs, 1)
        q_high = cfg.hl_pairs(pair_idx, 1);
        q_low = cfg.hl_pairs(pair_idx, 2);
        task_key = pair_task_key(method, q_high, q_low);
        task_dir = fullfile(cfg.stage_a.output_dir, task_key);
        sarvalid.ensure_dir(task_dir);
        checkpoint_path = fullfile(task_dir, "candidate_checkpoint.mat");

        signature = struct("experiment", cfg.experiment_name, ...
            "stage", "A", "method", method, "q_high", q_high, ...
            "q_low", q_low, "alphas", cfg.baru_alpha, ...
            "threshold", cfg.threshold, "threshold_seed", cfg.threshold_seed, ...
            "manifest", develop_manifest(:, ["SampleID", "Scene", "File", "CStart"]));
        initial_state = struct("candidate_results", table(), "completed_keys", strings(0, 1));
        state = sarvalid.load_checkpoint(checkpoint_path, signature, initial_state);

        coarse_pairs = enumerate_coarse_pairs(cfg, method, q_high, q_low, S60);
        [state, coarse_rows] = evaluate_pairs( ...
            state, coarse_pairs, "coarse", development_cache, S60, cfg, checkpoint_path);

        if endsWith(method, "_SFT")
            best_coarse = sarvalid.select_best_candidate(coarse_rows);
            fine_pairs = enumerate_fine_pairs( ...
                cfg, method, q_high, q_low, S60, best_coarse);
            [state, ~] = evaluate_pairs( ...
                state, fine_pairs, "fine", development_cache, S60, cfg, checkpoint_path);
        end

        candidate_results = state.candidate_results;
        writetable(candidate_results, fullfile(task_dir, "candidate_results.csv"));
        best_row = sarvalid.select_best_candidate(candidate_results);
        locked_pair = pair_from_result(cfg, best_row);
        development = sarvalid.evaluate_pure_pair( ...
            development_cache, S60, locked_pair, cfg.normalization);
        verification = sarvalid.verify_pure_pair( ...
            verify_manifest, S60, locked_pair, development.norm_stats, cfg.diagnostics);

        writetable(development.detail, fullfile(task_dir, "development_detail.csv"));
        writetable(development.norm_stats, fullfile(task_dir, "normalization.csv"));
        writetable(verification.detail, fullfile(task_dir, "verification_detail.csv"));
        save(fullfile(task_dir, "locked_config.mat"), ...
            "locked_pair", "best_row", "development", "verification", "-v7.3");
        sarvalid.write_json(fullfile(task_dir, "locked_config.json"), locked_pair);

        all_candidates = [all_candidates; candidate_results]; %#ok<AGROW>
        locked_rows = [locked_rows; best_row]; %#ok<AGROW>
        locked_configs{end+1, 1} = locked_pair; %#ok<AGROW>
        verification_summaries = [verification_summaries; ...
            verification_summary_row(locked_pair, verification.summary)]; %#ok<AGROW>
        fprintf('Stage A锁定：%s\n', locked_pair.file_key);
    end
end

writetable(all_candidates, fullfile(cfg.stage_a.output_dir, "all_candidates.csv"));
writetable(locked_rows, fullfile(cfg.stage_a.output_dir, "locked_candidates.csv"));
writetable(verification_summaries, ...
    fullfile(cfg.stage_a.output_dir, "verification_summary.csv"));
save(fullfile(cfg.stage_a.output_dir, "stage_a_final.mat"), ...
    "cfg", "S60", "manifest", "all_candidates", "locked_rows", ...
    "locked_configs", "verification_summaries", "-v7.3");

outputs = struct("cfg", cfg, "manifest", manifest, ...
    "candidate_results", all_candidates, "locked", locked_rows, ...
    "locked_configs", {locked_configs}, ...
    "verification_summary", verification_summaries);
end

function pairs = enumerate_coarse_pairs(cfg, method, q_high, q_low, S60)
if startsWith(method, "BARU_")
    alphas = cfg.baru_alpha;
else
    alphas = 1;
end
pairs = cell(0, 1);
for alpha = alphas
    if endsWith(method, "_RT")
        threshold = default_threshold(cfg);
        pairs{end+1, 1} = sarvalid.make_pair_config( ...
            cfg, method, q_high, q_low, alpha, threshold); %#ok<AGROW>
    else
        candidates = sarvalid.sft_candidate_grid( ...
            cfg, method, q_high, q_low, alpha, S60);
        for row_idx = 1:height(candidates)
            threshold = threshold_from_row(cfg, candidates(row_idx, :));
            pairs{end+1, 1} = sarvalid.make_pair_config( ...
                cfg, method, q_high, q_low, alpha, threshold); %#ok<AGROW>
        end
    end
end
end

function pairs = enumerate_fine_pairs(cfg, method, q_high, q_low, S60, best)
best_struct = struct("STRdB", best.STRdB, ...
    "FrOverBr", best.FrOverBr, "FaOverBa", best.FaOverBa);
candidates = sarvalid.sft_candidate_grid( ...
    cfg, method, q_high, q_low, best.Alpha, S60, best_struct);
pairs = cell(height(candidates), 1);
for row_idx = 1:height(candidates)
    threshold = threshold_from_row(cfg, candidates(row_idx, :));
    pairs{row_idx} = sarvalid.make_pair_config( ...
        cfg, method, q_high, q_low, best.Alpha, threshold);
end
end

function [state, rows] = evaluate_pairs( ...
        state, pairs, stage, cache, S60, cfg, checkpoint_path)
rows = table();
for pair_idx = 1:numel(pairs)
    pair_cfg = pairs{pair_idx};
    key = pair_cfg.file_key;
    if isempty(state.candidate_results)
        existing = [];
    else
        existing = find(string(state.candidate_results.PairKey) == key, 1);
    end
    if ~isempty(existing)
        row = state.candidate_results(existing, :);
    else
        evaluation = sarvalid.evaluate_pure_pair( ...
            cache, S60, pair_cfg, cfg.normalization);
        row = sarvalid.candidate_row(pair_cfg, stage, evaluation);
        state.candidate_results = [state.candidate_results; row];
        state.completed_keys(end+1, 1) = key;
        sarvalid.atomic_save(checkpoint_path, struct("state", state));
    end
    rows = [rows; row]; %#ok<AGROW>
end
end

function threshold = threshold_from_row(cfg, row)
threshold = struct("As", cfg.threshold.As, "STR_dB", row.STRdB, ...
    "fr_over_Br", row.FrOverBr, "fa_over_Ba", row.FaOverBa, ...
    "phi0", cfg.threshold.phi0);
end

function threshold = default_threshold(cfg)
threshold = struct("As", cfg.threshold.As, "STR_dB", NaN, ...
    "fr_over_Br", 0, "fa_over_Ba", 0, "phi0", cfg.threshold.phi0);
end

function pair_cfg = pair_from_result(cfg, row)
threshold = struct("As", cfg.threshold.As, "STR_dB", row.STRdB, ...
    "fr_over_Br", row.FrOverBr, "fa_over_Ba", row.FaOverBa, ...
    "phi0", cfg.threshold.phi0);
pair_cfg = sarvalid.make_pair_config(cfg, row.Method, row.QHigh, ...
    row.QLow, row.Alpha, threshold);
end

function key = pair_task_key(method, q_high, q_low)
base = sarvalid.stable_file_key(method, q_high, 0.5);
key = char(base + "_L" + encode_number(q_low));
end

function value = encode_number(number)
value = string(sprintf('%.10g', number));
value = replace(value, ".", "p");
end

function row = verification_summary_row(pair_cfg, summary)
Method = string(pair_cfg.method);
PairKey = string(pair_cfg.file_key);
QHigh = pair_cfg.q_high;
QLow = pair_cfg.q_low;
Alpha = pair_cfg.alpha;
HPSNR_Mean = summary.HPSNR_Mean;
HSSIM_Mean = summary.HSSIM_Mean;
LPSNR_Mean = summary.LPSNR_Mean;
LSSIM_Mean = summary.LSSIM_Mean;
DeltaPSNR_Mean = summary.DeltaPSNR_Mean;
DeltaSSIM_Mean = summary.DeltaSSIM_Mean;
SampleCount = summary.SampleCount;
row = table(Method, PairKey, QHigh, QLow, Alpha, HPSNR_Mean, ...
    HSSIM_Mean, LPSNR_Mean, LSSIM_Mean, DeltaPSNR_Mean, ...
    DeltaSSIM_Mean, SampleCount);
end
