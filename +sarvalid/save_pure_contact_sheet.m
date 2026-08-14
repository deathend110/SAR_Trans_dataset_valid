function save_pure_contact_sheet(file_path, gt, high, low, title_text)
%SAVE_PURE_CONTACT_SHEET 保存纯H/L全图与亮点、边缘、细纹理局部图。

sarvalid.ensure_dir(fileparts(file_path));
figure_handle = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100, 100, 1500, 820]);
cleanup = onCleanup(@() close(figure_handle));
layout = tiledlayout(2, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
title(layout, title_text, 'Interpreter', 'none');
images = {gt, high, low, abs(double(high)-double(gt)), ...
    abs(double(low)-double(gt)), abs(double(high)-double(low))};
titles = ["GT", "H", "L", "|H-GT|", "|L-GT|", "|H-L|"];
for idx = 1:6
    nexttile;
    imagesc(images{idx});
    if idx <= 3
        clim([0, 1]);
    else
        clim([0, 0.5]);
    end
    axis image off;
    title(titles(idx));
end
colormap(figure_handle, gray(256));
exportgraphics(figure_handle, file_path, 'Resolution', 150);

[folder, name, extension] = fileparts(file_path);
zoom_path = fullfile(folder, name + "_zooms" + extension);
save_zoom_sheet(zoom_path, gt, high, low, title_text);
end

function save_zoom_sheet(file_path, gt, high, low, title_text)
regions = sarvalid.diagnostic_regions(double(gt), 96);
figure_handle = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100, 100, 1200, 1050]);
cleanup = onCleanup(@() close(figure_handle));
layout = tiledlayout(3, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
title(layout, title_text + " local diagnostics", 'Interpreter', 'none');
images = {gt, high, low};
row_names = ["GT", "H", "L"];
for row_idx = 1:3
    for region_idx = 1:3
        region = regions(region_idx);
        nexttile;
        imagesc(images{row_idx}(region.rows, region.cols), [0, 1]);
        axis image off;
        title(row_names(row_idx) + " / " + region.label);
    end
end
colormap(figure_handle, gray(256));
exportgraphics(figure_handle, file_path, 'Resolution', 180);
end
