function manifests = build_generator_confirmation_manifests(cfg, S60)
%BUILD_GENERATOR_CONFIRMATION_MANIFESTS 构造与旧实验轨迹隔离的确认清单。

old_stage_a = sarvalid.build_stage_a_manifest(cfg, S60);
old_stage_b = sarvalid.build_stage_b_manifest(cfg);
development = old_stage_a(old_stage_a.Split == "development", :);
bridge = old_stage_a(old_stage_a.Split == "verification", :);

confirmation = table();
sequence = table();
audit = table();
sample_id = cfg.generator_confirmation.confirmation_sample_id_start - 1;
sequence_id = cfg.generator_confirmation.sequence_id_start - 1;

for scene_idx = 1:numel(cfg.dataset_names)
    scene = cfg.dataset_names(scene_idx);
    files = dir(fullfile(cfg.data_root, scene, "rstart*.mat"));
    [~, order] = sort({files.name});
    files = files(order);

    old_files = unique([ ...
        string(old_stage_a.File(old_stage_a.Scene == scene)); ...
        string(old_stage_b.File(old_stage_b.Scene == scene))]);
    keep = ~ismember(string({files.name}), old_files);
    unused = files(keep);
    required = cfg.generator_confirmation.confirmation_trajectories_per_scene + ...
        cfg.generator_confirmation.sequence_files_per_scene;
    if numel(unused) < required
        error('sarvalid:InsufficientConfirmationFiles', ...
            '场景%s仅有%d条未使用轨迹，确认实验至少需要%d条。', ...
            scene, numel(unused), required);
    end

    confirmation_positions = quantile_positions(numel(unused), ...
        cfg.generator_confirmation.confirmation_trajectories_per_scene);
    confirmation_files = unused(confirmation_positions);
    unused(confirmation_positions) = [];
    sequence_positions = quantile_positions(numel(unused), ...
        cfg.generator_confirmation.sequence_files_per_scene);
    sequence_files = unused(sequence_positions);

    for file_idx = 1:numel(confirmation_files)
        file = confirmation_files(file_idx);
        file_path = fullfile(file.folder, file.name);
        raw_width = first_variable_width(file_path);
        starts = stratified_starts(raw_width, S60.nan, ...
            cfg.generator_confirmation.confirmation_samples_per_trajectory);
        count = numel(starts);
        SampleID = (sample_id + (1:count)).';
        SceneIdx = repmat(scene_idx, count, 1);
        Scene = repmat(scene, count, 1);
        Split = repmat("confirmation", count, 1);
        File = repmat(string(file.name), count, 1);
        FilePath = repmat(string(file_path), count, 1);
        CStart = starts(:);
        WindowWidth = repmat(S60.nan, count, 1);
        confirmation = append_table(confirmation, ...
            table(SampleID, SceneIdx, Scene, Split, File, FilePath, ...
            CStart, WindowWidth));
        sample_id = sample_id + count;
    end

    for local_idx = 1:numel(sequence_files)
        file = sequence_files(local_idx);
        file_path = fullfile(file.folder, file.name);
        raw_width = first_variable_width(file_path);
        max_start = raw_width - cfg.sequence.block_width + 1;
        if max_start < 1
            error('sarvalid:ShortConfirmationSequence', ...
                '轨迹%s不足以裁出%d列连续块。', ...
                file.name, cfg.sequence.block_width);
        end
        c_start = min(max(round((local_idx - 0.5) / ...
            numel(sequence_files) * max_start), 1), max_start);
        sequence_id = sequence_id + 1;
        if local_idx == 1
            split = "calibration";
        else
            split = "evaluation";
        end
        row = table(sequence_id, scene_idx, scene, split, ...
            string(file.name), string(file_path), c_start, ...
            cfg.sequence.block_width, ...
            'VariableNames', ["SequenceID", "SceneIdx", "Scene", ...
            "Split", "File", "FilePath", "CStart", "BlockWidth"]);
        sequence = append_table(sequence, row);
    end

    OldFileCount = numel(old_files);
    UnusedFileCount = numel(unused) + numel(confirmation_files);
    ConfirmationFileCount = numel(confirmation_files);
    SequenceFileCount = numel(sequence_files);
    OldNewDisjoint = isempty(intersect(old_files, ...
        [string({confirmation_files.name}), string({sequence_files.name})]));
    StageABDisjoint = isempty(intersect(string({confirmation_files.name}), ...
        string({sequence_files.name})));
    audit = append_table(audit, table(scene, OldFileCount, ...
        UnusedFileCount, ConfirmationFileCount, SequenceFileCount, ...
        OldNewDisjoint, StageABDisjoint, ...
        'VariableNames', ["Scene", "OldFileCount", "UnusedFileCount", ...
        "ConfirmationFileCount", "SequenceFileCount", ...
        "OldNewDisjoint", "StageABDisjoint"]));
end

if height(development) ~= 14 || height(bridge) ~= 70 || ...
        height(confirmation) ~= 140 || ...
        sum(sequence.Split == "calibration") ~= 7 || ...
        sum(sequence.Split == "evaluation") ~= 28
    error('sarvalid:ConfirmationManifestCounts', ...
        '确认清单未满足14/70/140样本和7/28序列协议。');
end
if ~all(audit.OldNewDisjoint & audit.StageABDisjoint)
    error('sarvalid:ConfirmationManifestOverlap', ...
        '确认实验清单存在新旧轨迹或Stage A/B轨迹重叠。');
end

manifests = struct("development", development, ...
    "bridge_verification", bridge, "confirmation", confirmation, ...
    "sequence", sequence, "audit", audit, ...
    "hashes", struct( ...
    "development", table_hash(development), ...
    "bridge_verification", table_hash(bridge), ...
    "confirmation", table_hash(confirmation), ...
    "sequence", table_hash(sequence)));
end

function positions = quantile_positions(count, requested)
positions = ceil(((1:requested) - 0.5) / requested * count);
positions = min(max(positions, 1), count);
if numel(unique(positions)) ~= requested
    error('sarvalid:ConfirmationQuantileSelection', ...
        '分层轨迹选择产生重复位置。');
end
end

function width = first_variable_width(file_path)
variables = whos('-file', file_path);
if isempty(variables)
    error('sarvalid:EmptyConfirmationTrajectory', ...
        '轨迹文件为空：%s', file_path);
end
width = variables(1).size(2);
end

function starts = stratified_starts(raw_width, window_width, count)
max_start = raw_width - window_width + 1;
if max_start < 1
    error('sarvalid:ShortConfirmationTrajectory', ...
        '轨迹宽度不足以裁出完整确认窗口。');
end
starts = zeros(count, 1);
for idx = 1:count
    starts(idx) = min(max(round((idx - 0.5) / count * max_start), 1), ...
        max_start);
end
end

function digest = table_hash(input)
records = table2struct(input);
digest = sarvalid.sha256_text(string(jsonencode(records)));
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
