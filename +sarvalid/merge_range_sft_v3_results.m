function result = merge_range_sft_v3_results(base, addition)
%MERGE_RANGE_SFT_V3_RESULTS 合并基线与新增V3阶段结果并重新排名。

required = ["scene_metrics", "normalization_stats"];
if ~all(isfield(base, required)) || ~all(isfield(addition, required))
    error('sarvalid:V3MergeSchema', ...
        'V3阶段结果必须包含scene_metrics和normalization_stats。');
end

result = struct();
result.scene_metrics = append_table(base.scene_metrics, ...
    addition.scene_metrics);
result.normalization_stats = append_table( ...
    base.normalization_stats, addition.normalization_stats);
result.candidate_summary = sarvalid.rank_range_sft_v3_candidates( ...
    result.scene_metrics);
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
