function regions = diagnostic_regions(gt, region_size)
%DIAGNOSTIC_REGIONS 自动选择亮点、强边缘和细纹理三个代表性局部区域。

arguments
    gt (:, :) double
    region_size (1, 1) double {mustBePositive, mustBeInteger} = 96
end

gt = double(gt);
[gx, gy] = gradient(gt);
edge_score = hypot(gx, gy);
kernel = ones(9) / 81;
local_mean = conv2(gt, kernel, 'same');
texture_score = max(conv2(gt.^2, kernel, 'same') - local_mean.^2, 0);

[~, bright_index] = max(gt(:));
[~, edge_index] = max(edge_score(:));
[~, texture_index] = max(texture_score(:));
indices = [bright_index, edge_index, texture_index];
labels = ["bright", "edge", "texture"];

half = floor(region_size / 2);
regions = repmat(struct("label", "", "rows", [], "cols", []), 3, 1);
for idx = 1:3
    [row, col] = ind2sub(size(gt), indices(idx));
    row_start = min(max(row-half, 1), size(gt, 1)-region_size+1);
    col_start = min(max(col-half, 1), size(gt, 2)-region_size+1);
    regions(idx) = struct("label", labels(idx), ...
        "rows", row_start:row_start+region_size-1, ...
        "cols", col_start:col_start+region_size-1);
end
end
