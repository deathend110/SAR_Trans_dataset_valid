function ranked = rank_range_sft_v3_candidates(scene_metrics)
%RANK_RANGE_SFT_V3_CANDIDATES 按预注册顺序汇总并排序V3候选。

if isempty(scene_metrics)
    ranked = table();
    return;
end
required = ["Stage", "PairKey", "QHigh", "QLow", "STRdB", ...
    "FrOverBr", "FaOverBa", "Scene", "MeanPSNR", "MeanSSIM", ...
    "WorstSSIM", "LRegionSSIM"];
if ~all(ismember(required, string(scene_metrics.Properties.VariableNames)))
    error('sarvalid:V3RankingSchema', 'V3候选场景表缺少必要变量。');
end

groups = unique(scene_metrics(:, ["Stage", "PairKey", "QHigh", ...
    "QLow", "STRdB", "FrOverBr", "FaOverBa"]), 'rows', 'stable');
row_count = height(groups);
SceneCount = zeros(row_count, 1);
MeanPSNR = zeros(row_count, 1);
MeanSSIM = zeros(row_count, 1);
WorstSSIM = zeros(row_count, 1);
LRegionSSIM = zeros(row_count, 1);
GradientRMSE = zeros(row_count, 1);
BrightScattererError = zeros(row_count, 1);
BoundaryGradientExcess = zeros(row_count, 1);
OverlapExcessSSIMLoss = zeros(row_count, 1);
RangeLeakageRatio = zeros(row_count, 1);
AzimuthLeakageRatio = zeros(row_count, 1);
for idx = 1:row_count
    mask = string(scene_metrics.PairKey) == string(groups.PairKey(idx));
    rows = scene_metrics(mask, :);
    SceneCount(idx) = numel(unique(string(rows.Scene)));
    MeanPSNR(idx) = mean(rows.MeanPSNR);
    MeanSSIM(idx) = mean(rows.MeanSSIM);
    WorstSSIM(idx) = mean(rows.WorstSSIM);
    LRegionSSIM(idx) = mean(rows.LRegionSSIM, 'omitnan');
    GradientRMSE(idx) = optional_mean(rows, "GradientRMSE");
    BrightScattererError(idx) = optional_mean(rows, "BrightScattererError");
    BoundaryGradientExcess(idx) = optional_mean(rows, "BoundaryGradientExcess");
    OverlapExcessSSIMLoss(idx) = optional_mean(rows, "OverlapExcessSSIMLoss");
    RangeLeakageRatio(idx) = optional_mean(rows, "RangeLeakageRatio");
    AzimuthLeakageRatio(idx) = optional_mean(rows, "AzimuthLeakageRatio");
end
ranked = [groups, table(SceneCount, MeanPSNR, MeanSSIM, WorstSSIM, ...
    LRegionSSIM, GradientRMSE, BrightScattererError, ...
    BoundaryGradientExcess, OverlapExcessSSIMLoss, ...
    RangeLeakageRatio, AzimuthLeakageRatio)];
ranked = sortrows(ranked, ...
    ["MeanSSIM", "LRegionSSIM", "WorstSSIM", "MeanPSNR", "PairKey"], ...
    ["descend", "descend", "descend", "descend", "ascend"]);
Rank = (1:height(ranked)).';
ranked = addvars(ranked, Rank, 'Before', 1);
end

function value = optional_mean(rows, name)
if ismember(name, string(rows.Properties.VariableNames))
    value = mean(rows.(name), 'omitnan');
else
    value = NaN;
end
end
