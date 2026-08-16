function result = run_range_sft_v3_final( ...
        cfg, S60, manifest, cache_index, locked, final_dir, signature_context)
%RUN_RANGE_SFT_V3_FINAL 用锁定候选重跑并保存完整序列级诊断结果。

sarvalid.ensure_dir(final_dir);
contact_root = fullfile(final_dir, "contact_sheets");
sarvalid.ensure_dir(contact_root);
checkpoint_path = fullfile(final_dir, "final_checkpoint.mat");
signature = final_signature(cfg, S60, manifest, locked, signature_context);
initial_state = struct("completed_units", strings(0, 1), ...
    "scene_summary", table(), "sequence_summary", table(), ...
    "per_frame_metrics", table(), "overlap_metrics", table(), ...
    "normalization_stats", table());
if cfg.range_2dsft_v3.resume
    state = sarvalid.load_checkpoint( ...
        string(checkpoint_path), signature, initial_state);
else
    state = initial_state;
    state.signature = signature;
end

scenes = unique(string(manifest.Scene), 'stable');
for candidate_idx = 1:height(locked)
    candidate = locked(candidate_idx, :);
    pair = sarvalid.range_sft_v3_pair_from_row(cfg, candidate);
    pair_contact_dir = fullfile(contact_root, safe_name(pair.file_key));
    for scene_idx = 1:numel(scenes)
        scene = scenes(scene_idx);
        unit_key = string(pair.file_key) + "|" + scene;
        if any(state.completed_units == unit_key)
            continue;
        end
        scene_manifest = manifest(string(manifest.Scene) == scene, :);
        cache_path = cache_index.Path(cache_index.Scene == scene);
        evaluated = sarvalid.evaluate_range_sft_v3_scene( ...
            cfg, S60, scene_manifest, pair, cache_path, ...
            CollectDetails=true, ContactDirectory=string(pair_contact_dir));
        evaluated.scene_metrics.Stage(:) = "final";
        stage_column = repmat("final", height(evaluated.normalization), 1);
        evaluated.normalization = addvars(evaluated.normalization, ...
            stage_column, 'Before', 1, 'NewVariableNames', "Stage");
        state.scene_summary = append_table( ...
            state.scene_summary, evaluated.scene_metrics);
        state.sequence_summary = append_table( ...
            state.sequence_summary, evaluated.sequence_detail);
        state.per_frame_metrics = append_table( ...
            state.per_frame_metrics, evaluated.frame_detail);
        state.overlap_metrics = append_table( ...
            state.overlap_metrics, evaluated.overlap_detail);
        state.normalization_stats = append_table( ...
            state.normalization_stats, evaluated.normalization);
        state.completed_units(end + 1, 1) = unit_key;
        sarvalid.atomic_save(string(checkpoint_path), struct("state", state));
    end
end

writetable(state.sequence_summary, ...
    fullfile(final_dir, "sequence_summary.csv"));
writetable(state.per_frame_metrics, ...
    fullfile(final_dir, "per_frame_metrics.csv"));
writetable(state.scene_summary, fullfile(final_dir, "scene_summary.csv"));
writetable(state.normalization_stats, ...
    fullfile(final_dir, "normalization_stats.csv"));
writetable(state.overlap_metrics, fullfile(final_dir, "overlap_metrics.csv"));
result = rmfield(state, {'signature', 'completed_units'});
end

function signature = final_signature(cfg, S60, manifest, locked, context)
v3 = cfg.range_2dsft_v3;
signature = struct("experiment", v3.version, "stage", "final", ...
    "locked", locked, "signature_context", context, ...
    "manifest_hash", sarvalid.sha256_text( ...
    string(jsonencode(table2struct(manifest)))), ...
    "normalization", struct("roi_size", v3.normalization_roi_size, ...
    "patch_size", v3.metric_patch_size, ...
    "percentiles", [v3.low_percentile, v3.high_percentile], ...
    "frame_policy", "F0_F8_H_other_L"), ...
    "energy", struct("buffer", v3.energy_buffer, ...
    "policy", "single_full_block_H_to_L_scale"), ...
    "sequence", cfg.sequence, "phi0", cfg.threshold.phi0, ...
    "time_origin", "block_global", "imaging", imaging_signature(S60));
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

function output = safe_name(input)
output = regexprep(string(input), '[^A-Za-z0-9_-]+', '_');
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
