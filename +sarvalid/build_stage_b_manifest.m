function manifest = build_stage_b_manifest(cfg)
%BUILD_STAGE_B_MANIFEST 为每场景选择3条与Stage A不重叠的连续序列。

rows = table();
sequence_id = 0;
for scene_idx = 1:numel(cfg.dataset_names)
    scene = cfg.dataset_names(scene_idx);
    files = dir(fullfile(cfg.data_root, scene, "rstart*.mat"));
    [~, order] = sort({files.name});
    files = files(order);
    if numel(files) < 5
        error('sarvalid:InsufficientSequenceFiles', ...
            '场景%s至少需要5条轨迹以隔离Stage A/B。', scene);
    end

    verify_idx = mod(cfg.sample_seed, numel(files)) + 1;
    develop_idx = mod(verify_idx, numel(files)) + 1;
    candidate_indices = mod(develop_idx + (1:numel(files)), numel(files)) + 1;
    candidate_indices = candidate_indices( ...
        candidate_indices ~= verify_idx & candidate_indices ~= develop_idx);
    selected_indices = candidate_indices(1:cfg.stage_b.sequences_per_scene);

    for local_idx = 1:numel(selected_indices)
        file = files(selected_indices(local_idx));
        file_path = fullfile(file.folder, file.name);
        variables = whos('-file', file_path);
        raw_width = variables(1).size(2);
        max_start = raw_width - cfg.sequence.block_width + 1;
        if max_start < 1
            error('sarvalid:ShortSequenceTrajectory', ...
                '轨迹%s不足以裁出%d列连续块。', file.name, cfg.sequence.block_width);
        end
        c_start = min(max(round((local_idx - 0.5) / ...
            cfg.stage_b.sequences_per_scene * max_start), 1), max_start);
        sequence_id = sequence_id + 1;
        if local_idx <= cfg.stage_b.calibration_sequences_per_scene
            split = "calibration";
        else
            split = "evaluation";
        end
        row = table(sequence_id, scene_idx, scene, split, string(file.name), ...
            string(file_path), c_start, cfg.sequence.block_width, ...
            'VariableNames', ["SequenceID", "SceneIdx", "Scene", "Split", ...
            "File", "FilePath", "CStart", "BlockWidth"]);
        rows = [rows; row]; %#ok<AGROW>
    end
end
manifest = rows;
end
