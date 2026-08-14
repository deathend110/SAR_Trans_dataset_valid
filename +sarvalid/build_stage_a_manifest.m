function manifest = build_stage_a_manifest(cfg, S60)
%BUILD_STAGE_A_MANIFEST 构造14开发样本与70独立验证样本清单。

rows = table();
sample_id = 0;
for scene_idx = 1:numel(cfg.dataset_names)
    scene = cfg.dataset_names(scene_idx);
    files = dir(fullfile(cfg.data_root, scene, "rstart*.mat"));
    [~, order] = sort({files.name});
    files = files(order);
    if numel(files) < 2
        error('sarvalid:InsufficientSceneFiles', ...
            '场景%s至少需要两条轨迹。', scene);
    end

    verify_idx = mod(cfg.sample_seed, numel(files)) + 1;
    develop_idx = mod(verify_idx, numel(files)) + 1;
    definitions = { ...
        "development", files(develop_idx), cfg.stage_a.development_samples_per_scene; ...
        "verification", files(verify_idx), cfg.stage_a.verification_samples_per_scene};

    for definition_idx = 1:size(definitions, 1)
        split = definitions{definition_idx, 1};
        file = definitions{definition_idx, 2};
        sample_count = definitions{definition_idx, 3};
        file_path = fullfile(file.folder, file.name);
        variables = whos('-file', file_path);
        if isempty(variables)
            error('sarvalid:EmptyTrajectoryFile', '轨迹文件为空：%s', file_path);
        end
        raw_width = variables(1).size(2);
        starts = stratified_starts(raw_width, S60.nan, sample_count);

        count = numel(starts);
        SampleID = (sample_id + (1:count)).';
        SceneIdx = repmat(scene_idx, count, 1);
        Scene = repmat(scene, count, 1);
        Split = repmat(split, count, 1);
        File = repmat(string(file.name), count, 1);
        FilePath = repmat(string(file_path), count, 1);
        CStart = starts(:);
        WindowWidth = repmat(S60.nan, count, 1);
        rows = [rows; table(SampleID, SceneIdx, Scene, Split, File, ...
            FilePath, CStart, WindowWidth)]; %#ok<AGROW>
        sample_id = sample_id + count;
    end
end
manifest = rows;
end

function starts = stratified_starts(raw_width, window_width, count)
max_start = raw_width - window_width + 1;
if max_start < 1
    error('sarvalid:ShortTrajectory', '轨迹宽度不足以裁出完整窗口。');
end
starts = zeros(count, 1);
for idx = 1:count
    starts(idx) = min(max(round((idx - 0.5) / count * max_start), 1), max_start);
end
end
