function save_sequence_contact_sheet(file_path, input_seq, gt_seq, title_text)
%SAVE_SEQUENCE_CONTACT_SHEET 保存GT、输入和绝对误差九帧审计图。

figure_handle = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100, 100, 1800, 650]);
cleanup = onCleanup(@() close(figure_handle));
layout = tiledlayout(3, size(input_seq, 3), ...
    'TileSpacing', 'compact', 'Padding', 'compact');
title(layout, title_text, 'Interpreter', 'none');
for frame_idx = 1:size(input_seq, 3)
    nexttile;
    imagesc(gt_seq(:, :, frame_idx), [0, 1]);
    axis image off;
    if frame_idx == 1, ylabel('GT'); end
    title(sprintf('F%d', frame_idx-1));
end
for frame_idx = 1:size(input_seq, 3)
    nexttile;
    imagesc(input_seq(:, :, frame_idx), [0, 1]);
    axis image off;
    if frame_idx == 1, ylabel('Input'); end
end
for frame_idx = 1:size(input_seq, 3)
    nexttile;
    imagesc(abs(double(input_seq(:, :, frame_idx)) - ...
        double(gt_seq(:, :, frame_idx))), [0, 0.5]);
    axis image off;
    if frame_idx == 1, ylabel('|Diff|'); end
end
colormap(figure_handle, gray(256));
exportgraphics(figure_handle, file_path, 'Resolution', 150);

% 中间帧通常同时覆盖模式过渡和稳定纹理，另存三类局部放大图。
[folder, name, extension] = fileparts(file_path);
zoom_path = fullfile(folder, name + "_zooms" + extension);
middle_frame = ceil(size(input_seq, 3) / 2);
save_zoom_sheet(zoom_path, input_seq(:, :, middle_frame), ...
    gt_seq(:, :, middle_frame), title_text, middle_frame-1);
end

function save_zoom_sheet(file_path, input_image, gt_image, title_text, frame_idx)
regions = sarvalid.diagnostic_regions(double(gt_image), 96);
figure_handle = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100, 100, 1200, 1050]);
cleanup = onCleanup(@() close(figure_handle));
layout = tiledlayout(3, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
title(layout, sprintf('%s F%d local diagnostics', title_text, frame_idx), ...
    'Interpreter', 'none');
images = {gt_image, input_image, abs(double(input_image)-double(gt_image))};
row_names = ["GT", "Input", "|Diff|"];
for row_idx = 1:3
    for region_idx = 1:3
        region = regions(region_idx);
        nexttile;
        imagesc(images{row_idx}(region.rows, region.cols));
        axis image off;
        title(row_names(row_idx) + " / " + region.label);
        if row_idx < 3
            clim([0, 1]);
        else
            clim([0, 0.5]);
        end
    end
end
colormap(figure_handle, gray(256));
exportgraphics(figure_handle, file_path, 'Resolution', 180);
end
