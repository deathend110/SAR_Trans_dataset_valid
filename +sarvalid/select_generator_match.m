function [selected, audit] = select_generator_match( ...
        range_candidates, baru_candidate, tolerance)
%SELECT_GENERATOR_MATCH 为Range+2D-SFT选择与BARU+RT难度相近的候选。

arguments
    range_candidates table
    baru_candidate table
    tolerance (1, 1) struct
end
if height(baru_candidate) ~= 1
    error('sarvalid:GeneratorMatchBARURow', 'BARU目标候选必须恰好一行。');
end
required = ["L_SSIM_Mean", "Delta_SSIM_Mean", ...
    "Worst_SSIM", "Pair_SSIM_Mean", "Pair_PSNR_Mean"];
if ~all(ismember(required, string(range_candidates.Properties.VariableNames)))
    error('sarvalid:GeneratorMatchSchema', 'Range候选缺少难度匹配字段。');
end

target_l = baru_candidate.L_SSIM_Mean;
target_delta = baru_candidate.Delta_SSIM_Mean;
l_error = abs(range_candidates.L_SSIM_Mean - target_l);
delta_error = abs(range_candidates.Delta_SSIM_Mean - target_delta);

[selected, status, used_l, used_delta] = choose_feasible( ...
    range_candidates, l_error, delta_error, ...
    tolerance.l_ssim, tolerance.delta_ssim, "matched");
if isempty(selected)
    [selected, status, used_l, used_delta] = choose_feasible( ...
        range_candidates, l_error, delta_error, ...
        tolerance.expanded_l_ssim, tolerance.expanded_delta_ssim, ...
        "matched_expanded");
end
if isempty(selected)
    distance = l_error / tolerance.expanded_l_ssim + ...
        delta_error / tolerance.expanded_delta_ssim;
    ranking = [distance, -range_candidates.Worst_SSIM, ...
        -range_candidates.Pair_SSIM_Mean, ...
        -range_candidates.Pair_PSNR_Mean];
    [~, order] = sortrows(ranking, [1, 2, 3, 4]);
    selected = range_candidates(order(1), :);
    status = "failed_closest";
    used_l = tolerance.expanded_l_ssim;
    used_delta = tolerance.expanded_delta_ssim;
end

Status = status;
TargetLSSIM = target_l;
TargetDeltaSSIM = target_delta;
SelectedPairKey = string(selected.PairKey);
SelectedLSSIM = selected.L_SSIM_Mean;
SelectedDeltaSSIM = selected.Delta_SSIM_Mean;
AbsLSSIMError = abs(SelectedLSSIM - TargetLSSIM);
AbsDeltaSSIMError = abs(SelectedDeltaSSIM - TargetDeltaSSIM);
UsedLSSIMTolerance = used_l;
UsedDeltaSSIMTolerance = used_delta;
DifficultyMatched = startsWith(Status, "matched");
audit = table(Status, DifficultyMatched, TargetLSSIM, ...
    TargetDeltaSSIM, SelectedPairKey, SelectedLSSIM, ...
    SelectedDeltaSSIM, AbsLSSIMError, AbsDeltaSSIMError, ...
    UsedLSSIMTolerance, UsedDeltaSSIMTolerance);
end

function [selected, status, used_l, used_delta] = choose_feasible( ...
        candidates, l_error, delta_error, l_tolerance, delta_tolerance, label)
mask = l_error <= l_tolerance & delta_error <= delta_tolerance;
selected = table();
status = "";
used_l = l_tolerance;
used_delta = delta_tolerance;
if ~any(mask)
    return;
end
feasible = candidates(mask, :);
ranking = [-feasible.Worst_SSIM, -feasible.Pair_SSIM_Mean, ...
    -feasible.Pair_PSNR_Mean];
[~, order] = sortrows(ranking, [1, 2, 3]);
selected = feasible(order(1), :);
status = string(label);
end
