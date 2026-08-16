function result = run_range_sft_v3_search( ...
        cfg, S60, manifest, cache_index, candidates, stage_name, stage_dir, ...
        signature_context)
%RUN_RANGE_SFT_V3_SEARCH 按候选和场景运行V3搜索，并提供细粒度恢复。

arguments
    cfg (1, 1) struct
    S60 (1, 1) struct
    manifest table
    cache_index table
    candidates table
    stage_name (1, 1) string
    stage_dir (1, 1) string
    signature_context (1, 1) struct
end

sarvalid.ensure_dir(stage_dir);
all_scene_metrics = table();
all_normalization = table();
all_ranked = table();
pair_values = unique(candidates(:, ["QHigh", "QLow"]), 'rows', 'stable');
for pair_idx = 1:height(pair_values)
    q_high = pair_values.QHigh(pair_idx);
    q_low = pair_values.QLow(pair_idx);
    pair_mask = candidates.QHigh == q_high & candidates.QLow == q_low;
    pair_candidates = candidates(pair_mask, :);
    pair_dir = fullfile(stage_dir, pair_directory(q_high, q_low));
    sarvalid.ensure_dir(pair_dir);
    checkpoint_path = fullfile(pair_dir, "search_checkpoint.mat");
    signature = search_signature(cfg, S60, manifest, pair_candidates, ...
        stage_name, signature_context);
    initial_state = struct("completed_units", strings(0, 1), ...
        "scene_metrics", table(), "normalization", table());
    if cfg.range_2dsft_v3.resume
        state = sarvalid.load_checkpoint( ...
            string(checkpoint_path), signature, initial_state);
    else
        state = initial_state;
        state.signature = signature;
    end

    scenes = unique(string(manifest.Scene), 'stable');
    for candidate_idx = 1:height(pair_candidates)
        candidate = pair_candidates(candidate_idx, :);
        pair = sarvalid.range_sft_v3_pair_from_row(cfg, candidate);
        for scene_idx = 1:numel(scenes)
            scene = scenes(scene_idx);
            unit_key = string(pair.file_key) + "|" + scene;
            if any(state.completed_units == unit_key)
                continue;
            end
            scene_manifest = manifest(string(manifest.Scene) == scene, :);
            cache_path = cache_index.Path(cache_index.Scene == scene);
            if numel(cache_path) ~= 1
                error('sarvalid:V3GTCacheIndex', ...
                    '场景%s必须对应唯一GT缓存。', scene);
            end
            evaluated = sarvalid.evaluate_range_sft_v3_scene( ...
                cfg, S60, scene_manifest, pair, cache_path);
            evaluated.scene_metrics.Stage(:) = stage_name;
            stage_column = repmat(stage_name, ...
                height(evaluated.normalization), 1);
            evaluated.normalization = addvars(evaluated.normalization, ...
                stage_column, 'Before', 1, 'NewVariableNames', "Stage");
            state.scene_metrics = append_table( ...
                state.scene_metrics, evaluated.scene_metrics);
            state.normalization = append_table( ...
                state.normalization, evaluated.normalization);
            state.completed_units(end + 1, 1) = unit_key;
            sarvalid.atomic_save(string(checkpoint_path), struct("state", state));
        end
    end

    ranked = sarvalid.rank_range_sft_v3_candidates(state.scene_metrics);
    all_scene_metrics = append_table(all_scene_metrics, state.scene_metrics);
    all_normalization = append_table(all_normalization, state.normalization);
    all_ranked = append_table(all_ranked, ranked);
end

writetable(all_scene_metrics, fullfile(stage_dir, "candidate_scene_metrics.csv"));
writetable(all_ranked, fullfile(stage_dir, "candidate_summary.csv"));
writetable(all_normalization, fullfile(stage_dir, "normalization_stats.csv"));
result = struct("scene_metrics", all_scene_metrics, ...
    "candidate_summary", all_ranked, ...
    "normalization_stats", all_normalization);
end

function signature = search_signature( ...
        cfg, S60, manifest, candidates, stage_name, context)
v3 = cfg.range_2dsft_v3;
signature = struct("experiment", v3.version, "stage", stage_name, ...
    "candidates", candidates, "signature_context", context, ...
    "manifest_hash", table_hash(manifest), ...
    "manifest", manifest(:, ["SequenceID", "Scene", "File", ...
    "FilePath", "CStart", "BlockWidth"]), ...
    "normalization", struct("roi_size", v3.normalization_roi_size, ...
    "patch_size", v3.metric_patch_size, ...
    "low_percentile", v3.low_percentile, ...
    "high_percentile", v3.high_percentile, ...
    "order", "pool_600_then_normalize_then_center_crop_512", ...
    "frame_policy", "F0_F8_H_other_L"), ...
    "energy", struct("buffer", v3.energy_buffer, ...
    "policy", "single_full_block_H_to_L_scale"), ...
    "sft", struct("phi0", cfg.threshold.phi0, ...
    "time_origin", "block_global", "shared_HL_parameters", true, ...
    "nyquist_margin", cfg.threshold.nyquist_margin), ...
    "sequence", cfg.sequence, "imaging", imaging_signature(S60), ...
    "ranking", ["MeanSSIM_desc", "LRegionSSIM_desc", ...
    "WorstSSIM_desc", "MeanPSNR_desc", "PairKey_asc"]);
end

function digest = table_hash(input)
digest = sarvalid.sha256_text(string(jsonencode(table2struct(input))));
end

function value = imaging_signature(S60)
names = ["fc", "B", "Fs", "prf", "R0", "C", "v", ...
    "Tp", "Ta", "nrn", "nan", "R_total", "A_num"];
value = struct();
for name = names
    if isfield(S60, name)
        value.(name) = S60.(name);
    end
end
end

function output = pair_directory(q_high, q_low)
output = "qh" + encode(q_high) + "_ql" + encode(q_low);
end

function output = encode(value)
output = replace(string(sprintf('%.12g', value)), ".", "p");
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
