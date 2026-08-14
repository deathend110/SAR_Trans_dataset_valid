function ranked = pareto_rank(summary_table)
%PARETO_RANK 对Stage B配置执行非支配排序和预注册并列规则。

required = ["MeanPSNR", "MeanSSIM", "WorstPSNR", "WorstSSIM", ...
    "OverlapExcessRMSE", "OverlapExcessSSIMLoss", ...
    "BoundaryGradientExcess", "BoundaryJumpDB", ...
    "OffSupportRatio", "RangeLeakageRatio", "AzimuthLeakageRatio"];
if ~all(ismember(required, string(summary_table.Properties.VariableNames)))
    error('sarvalid:ParetoSchema', 'Stage B汇总表缺少Pareto目标列。');
end

objectives = [ ...
    -summary_table.MeanPSNR, -summary_table.MeanSSIM, ...
    -summary_table.WorstPSNR, -summary_table.WorstSSIM, ...
    summary_table.OverlapExcessRMSE, ...
    summary_table.OverlapExcessSSIMLoss, ...
    abs(summary_table.BoundaryGradientExcess), ...
    abs(summary_table.BoundaryJumpDB), ...
    summary_table.OffSupportRatio, ...
    summary_table.RangeLeakageRatio, ...
    summary_table.AzimuthLeakageRatio];
if any(~isfinite(objectives), 'all')
    error('sarvalid:ParetoNonfinite', ...
        'Pareto目标包含非有限值，必须先修复上游指标。');
end
remaining = (1:height(summary_table)).';
rank = zeros(height(summary_table), 1);
current_rank = 1;
while ~isempty(remaining)
    is_front = true(numel(remaining), 1);
    for i = 1:numel(remaining)
        for j = 1:numel(remaining)
            if i == j
                continue;
            end
            a = objectives(remaining(j), :);
            b = objectives(remaining(i), :);
            if all(a <= b) && any(a < b)
                is_front(i) = false;
                break;
            end
        end
    end
    front = remaining(is_front);
    rank(front) = current_rank;
    remaining = remaining(~is_front);
    current_rank = current_rank + 1;
end

ranked = addvars(summary_table, rank, 'NewVariableNames', "ParetoRank");
ranked = sortrows(ranked, ...
    ["ParetoRank", "WorstSSIM", "WorstPSNR"], ...
    ["ascend", "descend", "descend"]);
end
