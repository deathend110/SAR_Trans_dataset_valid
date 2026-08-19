function manifest = build_scene_percentile_manifest(cfg, blocks_per_file)
%BUILD_SCENE_PERCENTILE_MANIFEST 枚举全部场景文件并均匀抽取连续序列块。

arguments
    cfg (1, 1) struct
    blocks_per_file (1, 1) double {mustBePositive, mustBeInteger}
end

required = ["data_root", "dataset_names", "sequence"];
if ~all(isfield(cfg, required)) || ~isfield(cfg.sequence, "block_width")
    error('sarvalid:ScenePercentileConfigMissing', ...
        '配置必须包含data_root、dataset_names和sequence.block_width。');
end

rows = table();
sequence_id = 0;
for scene_idx = 1:numel(cfg.dataset_names)
    scene = string(cfg.dataset_names(scene_idx));
    scene_dir = fullfile(string(cfg.data_root), scene);
    if ~isfolder(scene_dir)
        error('sarvalid:ScenePercentileDirectoryMissing', ...
            '场景目录不存在：%s', scene_dir);
    end

    files = dir(fullfile(scene_dir, "rstart*.mat"));
    files = sort_echo_files(files);
    if isempty(files)
        error('sarvalid:ScenePercentileFilesMissing', ...
            '场景%s中没有rstart*.mat。', scene);
    end

    scene_key = sarvalid.scene_percentile_key(scene);
    for file_idx = 1:numel(files)
        file = files(file_idx);
        file_path = string(fullfile(file.folder, file.name));
        variables = whos('-file', file_path);
        if isempty(variables) || numel(variables(1).size) ~= 2
            error('sarvalid:ScenePercentileEchoSchema', ...
                '回波文件缺少二维变量：%s', file_path);
        end
        raw_width = variables(1).size(2);
        max_start = raw_width - cfg.sequence.block_width + 1;
        if max_start < blocks_per_file
            error('sarvalid:ScenePercentileEchoTooShort', ...
                '文件%s无法抽取%d个不同的宽度%d序列块。', ...
                file.name, blocks_per_file, cfg.sequence.block_width);
        end

        starts = unique(round(linspace(1, max_start, blocks_per_file)), ...
            'stable');
        if numel(starts) ~= blocks_per_file
            error('sarvalid:ScenePercentileStartsNotUnique', ...
                '文件%s的均匀CStart不足%d个不同位置。', ...
                file.name, blocks_per_file);
        end

        for block_idx = 1:blocks_per_file
            sequence_id = sequence_id + 1;
            SequenceID = sequence_id;
            SceneIdx = scene_idx;
            Scene = scene;
            SceneKey = scene_key;
            FileIdx = file_idx;
            File = string(file.name);
            FilePath = file_path;
            EchoVariable = string(variables(1).name);
            CStart = starts(block_idx);
            BlockWidth = cfg.sequence.block_width;
            RawWidth = raw_width;
            BlockIndex = block_idx;
            FileBytes = double(file.bytes);
            FileDatenum = double(file.datenum);
            row = table(SequenceID, SceneIdx, Scene, SceneKey, ...
                FileIdx, File, FilePath, EchoVariable, CStart, ...
                BlockWidth, RawWidth, BlockIndex, FileBytes, FileDatenum);
            rows = append_table(rows, row);
        end
    end
end
manifest = rows;
end

function files = sort_echo_files(files)
if isempty(files)
    return;
end
numbers = inf(numel(files), 1);
for idx = 1:numel(files)
    token = regexp(files(idx).name, ...
        '^rstart\s*([0-9]+)\.mat$', 'tokens', 'once', 'ignorecase');
    if ~isempty(token)
        numbers(idx) = str2double(token{1});
    end
end
names = lower(string({files.name})).';
order_table = table(numbers, names, (1:numel(files)).', ...
    'VariableNames', ["Number", "Name", "OriginalIndex"]);
order_table = sortrows(order_table, ["Number", "Name"]);
files = files(order_table.OriginalIndex);
end

function output = append_table(input, row)
if isempty(input)
    output = row;
else
    output = [input; row];
end
end
