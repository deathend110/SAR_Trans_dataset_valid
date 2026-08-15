function row = audit_baru_boundary(best, candidates, gc, q_high, q_low)
%AUDIT_BARU_BOUNDARY 判断扩展BARU最优点是否仍受硬边界截断。

tolerance = 1e-12;
AtAlphaBoundary = abs(best.Alpha - gc.baru_alpha_bounds(1)) <= tolerance || ...
    abs(best.Alpha - gc.baru_alpha_bounds(2)) <= tolerance;
AtAsBoundary = abs(best.As - gc.baru_As_bounds(1)) <= tolerance || ...
    abs(best.As - gc.baru_As_bounds(2)) <= tolerance;
AtAnyBoundary = AtAlphaBoundary || AtAsBoundary;
interior = candidates.Alpha > gc.baru_alpha_bounds(1) + tolerance & ...
    candidates.Alpha < gc.baru_alpha_bounds(2) - tolerance & ...
    candidates.As > gc.baru_As_bounds(1) + tolerance & ...
    candidates.As < gc.baru_As_bounds(2) - tolerance;
if any(interior)
    BestInteriorPairSSIM = max(candidates.Pair_SSIM_Mean(interior));
    BoundaryGain = best.Pair_SSIM_Mean - BestInteriorPairSSIM;
else
    BestInteriorPairSSIM = NaN;
    BoundaryGain = Inf;
end
SearchClosed = ~AtAnyBoundary || ...
    BoundaryGain <= gc.baru_boundary_gain_tolerance;
if SearchClosed
    Status = "closed";
else
    Status = "BARU_search_not_closed";
end
QHigh = q_high;
QLow = q_low;
BestPairKey = string(best.PairKey);
BestAlpha = best.Alpha;
BestAs = best.As;
BestPairSSIM = best.Pair_SSIM_Mean;
GainTolerance = gc.baru_boundary_gain_tolerance;
row = table(QHigh, QLow, BestPairKey, BestAlpha, BestAs, ...
    BestPairSSIM, AtAlphaBoundary, AtAsBoundary, AtAnyBoundary, ...
    BestInteriorPairSSIM, BoundaryGain, GainTolerance, SearchClosed, Status);
end
