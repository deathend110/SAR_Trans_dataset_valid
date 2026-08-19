function stats = exact_percentiles_from_chunks( ...
        chunk_directory, percentages, modality, image_count)
%EXACT_PERCENTILES_FROM_CHUNKS 用tall列向量计算磁盘分块的精确分位数。

arguments
    chunk_directory (1, 1) string
    percentages (1, 2) double
    modality (1, 1) string
    image_count (1, 1) double {mustBeNonnegative, mustBeInteger}
end
if percentages(1) < 0 || percentages(2) > 100 || ...
        percentages(1) >= percentages(2)
    error('sarvalid:InvalidChunkPercentiles', ...
        '分位数必须满足0<=low<high<=100。');
end

files = dir(fullfile(chunk_directory, "chunk_*.mat"));
[~, order] = sort(lower(string({files.name})));
files = files(order);
if isempty(files)
    error('sarvalid:PercentileChunksMissing', ...
        '目录中没有分位数chunk：%s', chunk_directory);
end

paths = strings(numel(files), 1);
pixel_count = 0;
for idx = 1:numel(files)
    paths(idx) = string(fullfile(files(idx).folder, files(idx).name));
    variables = whos('-file', paths(idx));
    match = strcmp({variables.name}, 'values');
    if sum(match) ~= 1
        error('sarvalid:PercentileChunkSchema', ...
            'chunk必须且只能包含一个values变量：%s', paths(idx));
    end
    variable = variables(match);
    if ~strcmp(variable.class, 'single') || ...
            numel(variable.size) ~= 2 || variable.size(2) ~= 1
        error('sarvalid:PercentileChunkType', ...
            'chunk.values必须是single列向量：%s', paths(idx));
    end
    pixel_count = pixel_count + prod(variable.size);
end

datastore_value = fileDatastore(paths, ...
    'ReadFcn', @read_values, 'UniformRead', true);
% 强制使用本地MATLAB会话，避免精确分位数依赖并行许可证。
mapreducer(0);
tall_values = tall(datastore_value);
limits = gather(prctile(tall_values, percentages, Method="midpoint"));
limits = double(limits(:));
if numel(limits) ~= 2 || any(~isfinite(limits)) || limits(2) <= limits(1)
    error('sarvalid:DegenerateChunkPercentiles', ...
        '%s分位数范围无效。', modality);
end

stats = struct( ...
    "Modality", modality, ...
    "VMin", limits(1), ...
    "VMax", limits(2), ...
    "ImageCount", image_count, ...
    "PixelCount", pixel_count, ...
    "ChunkCount", numel(files), ...
    "LowPercentile", percentages(1), ...
    "HighPercentile", percentages(2), ...
    "Method", "midpoint_exact_tall");
end

function values = read_values(file_path)
loaded = load(file_path, 'values');
if ~isfield(loaded, 'values')
    error('sarvalid:PercentileChunkSchema', ...
        'chunk缺少values变量：%s', file_path);
end
values = loaded.values(:);
end
