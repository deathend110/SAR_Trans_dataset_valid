function scene_stats = upsert_scene_percentile_stats( ...
        file_path, header, gt_stats, entry)
%UPSERT_SCENE_PERCENTILE_STATS 原子新增或替换场景分位数参数条目。

arguments
    file_path (1, 1) string
    header (1, 1) struct
    gt_stats (1, 1) struct
    entry (1, 1) struct
end
required_header = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "source_manifest", "source_signature"];
required_entry = ["parameter_key", "parameters", "effective_sampling", ...
    "input_stats", "audit", "created_at", "updated_at"];
if ~all(isfield(header, required_header)) || ...
        ~all(isfield(entry, required_entry))
    error('sarvalid:ScenePercentileUpsertSchema', ...
        '场景header或参数entry缺少必要字段。');
end

now_text = string(datetime('now', ...
    'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
if isfile(file_path)
    loaded = load(file_path, 'scene_stats');
    if ~isfield(loaded, 'scene_stats')
        error('sarvalid:ScenePercentileFileSchema', ...
            'MAT文件缺少scene_stats变量：%s', file_path);
    end
    scene_stats = loaded.scene_stats;
    verify_header(scene_stats, header, file_path);
    if ~isequaln(scene_stats.gt.signature, gt_stats.signature)
        error('sarvalid:ScenePercentileGTSignatureMismatch', ...
            '已有GT统计与当前GT签名不一致：%s', file_path);
    end
else
    scene_stats = header;
    scene_stats.gt = gt_stats;
    scene_stats.entries = struct([]);
    scene_stats.created_at = now_text;
end

entry.updated_at = now_text;
keys = strings(0, 1);
if ~isempty(scene_stats.entries)
    keys = string({scene_stats.entries.parameter_key}).';
end
match = find(keys == string(entry.parameter_key));
if numel(match) > 1
    error('sarvalid:DuplicateScenePercentileKey', ...
        '已有MAT包含重复parameter_key：%s', entry.parameter_key);
elseif isempty(match)
    entry.created_at = now_text;
    if isempty(scene_stats.entries)
        scene_stats.entries = entry;
    else
        scene_stats.entries(end + 1) = entry;
    end
else
    entry.created_at = scene_stats.entries(match).created_at;
    scene_stats.entries(match) = entry;
end
scene_stats.updated_at = now_text;

sarvalid.atomic_save(file_path, struct("scene_stats", scene_stats));
end

function verify_header(scene_stats, header, file_path)
required = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "source_manifest", "source_signature", "gt", ...
    "entries", "created_at"];
if ~all(isfield(scene_stats, required))
    error('sarvalid:ScenePercentileFileSchema', ...
        '已有scene_stats结构不完整：%s', file_path);
end
same_identity = string(scene_stats.schema_version) == ...
        string(header.schema_version) && ...
    string(scene_stats.scene_name) == string(header.scene_name) && ...
    string(scene_stats.scene_key) == string(header.scene_key);
if ~same_identity || ~isequaln(scene_stats.protocol, header.protocol) || ...
        string(scene_stats.source_signature) ~= ...
        string(header.source_signature) || ...
        ~isequaln(scene_stats.source_manifest, header.source_manifest)
    error('sarvalid:ScenePercentileSourceSignatureMismatch', ...
        ['已有场景MAT与当前数据清单或公共统计协议不一致；' ...
        '请先人工归档旧文件：%s'], file_path);
end
end
