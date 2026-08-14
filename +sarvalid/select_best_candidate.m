function best = select_best_candidate(candidate_results)
%SELECT_BEST_CANDIDATE 按预注册规则锁定H/L联合最优候选。

valid = isfinite(candidate_results.Pair_SSIM_Mean) & ...
    isfinite(candidate_results.Pair_PSNR_Mean);
candidates = candidate_results(valid, :);
if isempty(candidates)
    error('sarvalid:NoValidCandidate', '没有可锁定的有限候选结果。');
end
abs_str = abs(candidates.STRdB);
abs_str(~isfinite(abs_str)) = 0;
frequency_sum = candidates.FrOverBr + candidates.FaOverBa;
sort_matrix = [-candidates.Pair_SSIM_Mean, -candidates.Pair_PSNR_Mean, ...
    abs_str, frequency_sum];
[~, order] = sortrows(sort_matrix, [1, 2, 3, 4]);
best = candidates(order(1), :);
end
