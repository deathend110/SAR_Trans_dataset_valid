function metrics = boundary_gradient_excess(input_seq, gt_seq, frame_masks)
%BOUNDARY_GRADIENT_EXCESS 统计H/L边界处相对GT的额外横向梯度。

values = zeros(0, 1);
ratios = zeros(0, 1);
for frame_idx = 1:size(input_seq, 3)
    boundaries = find(diff(frame_masks(frame_idx, :)) ~= 0);
    for boundary = boundaries
        input_gradient = mean(abs(double(input_seq(:, boundary+1, frame_idx)) - ...
            double(input_seq(:, boundary, frame_idx))));
        gt_gradient = mean(abs(double(gt_seq(:, boundary+1, frame_idx)) - ...
            double(gt_seq(:, boundary, frame_idx))));
        values(end+1, 1) = input_gradient - gt_gradient; %#ok<AGROW>
        ratios(end+1, 1) = input_gradient / (gt_gradient + eps); %#ok<AGROW>
    end
end
if isempty(values)
    metrics = struct("mean_excess", 0, "mean_ratio", 1, "boundary_count", 0);
else
    metrics = struct("mean_excess", mean(values), ...
        "mean_ratio", mean(ratios), "boundary_count", numel(values));
end
end
