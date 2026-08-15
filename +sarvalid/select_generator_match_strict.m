function [selected, audit] = select_generator_match_strict( ...
        range_candidates, baru_candidate, tolerance)
%SELECT_GENERATOR_MATCH_STRICT 仅按首轮容差执行生成器难度匹配。

arguments
    range_candidates table
    baru_candidate table
    tolerance (1, 1) struct
end
if height(baru_candidate) ~= 1
    error('sarvalid:StrictMatchBARURow', 'BARU目标候选必须恰好一行。');
end
required = ["L_SSIM_Mean", "Delta_SSIM_Mean", ...
    "Worst_SSIM", "Pair_SSIM_Mean", "Pair_PSNR_Mean"];
if ~all(ismember(required, string(range_candidates.Properties.VariableNames)))
    error('sarvalid:StrictMatchSchema', 'Range候选缺少难度匹配字段。');
end

target_l = baru_candidate.L_SSIM_Mean;
target_delta = baru_candidate.Delta_SSIM_Mean;
l_error = abs(range_candidates.L_SSIM_Mean - target_l);
delta_error = abs(range_candidates.Delta_SSIM_Mean - target_delta);
feasible = l_error <= tolerance.l_ssim & ...
    delta_error <= tolerance.delta_ssim;
if any(feasible)
    rows = range_candidates(feasible, :);
    rows = sortrows(rows, ["Worst_SSIM", "Pair_SSIM_Mean", ...
        "Pair_PSNR_Mean", "PairKey"], ...
        ["descend", "descend", "descend", "ascend"]);
    selected = rows(1, :);
    status = "matched_strict";
else
    distance = l_error / tolerance.l_ssim + ...
        delta_error / tolerance.delta_ssim;
    ranking = [distance, -range_candidates.Worst_SSIM, ...
        -range_candidates.Pair_SSIM_Mean, ...
        -range_candidates.Pair_PSNR_Mean];
    [~, order] = sortrows(ranking, [1, 2, 3, 4]);
    selected = range_candidates(order(1), :);
    status = "failed_closest";
end

Status = status;
DifficultyMatched = status == "matched_strict";
TargetLSSIM = target_l;
TargetDeltaSSIM = target_delta;
SelectedPairKey = string(selected.PairKey);
SelectedLSSIM = selected.L_SSIM_Mean;
SelectedDeltaSSIM = selected.Delta_SSIM_Mean;
AbsLSSIMError = abs(SelectedLSSIM - TargetLSSIM);
AbsDeltaSSIMError = abs(SelectedDeltaSSIM - TargetDeltaSSIM);
UsedLSSIMTolerance = tolerance.l_ssim;
UsedDeltaSSIMTolerance = tolerance.delta_ssim;
audit = table(Status, DifficultyMatched, TargetLSSIM, ...
    TargetDeltaSSIM, SelectedPairKey, SelectedLSSIM, ...
    SelectedDeltaSSIM, AbsLSSIMError, AbsDeltaSSIMError, ...
    UsedLSSIMTolerance, UsedDeltaSSIMTolerance);
end
